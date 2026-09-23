#if os(Android)
  import Android
  import DriftboxHost
  import Synchronization

  /// Messages held until the moment they are stamped with, then sent, stamp and all.
  ///
  /// Android's MIDI takes a stamp with every message, but only a device that keeps to stamps
  /// plays it then: Android's USB driver does, and another app, measured against the app's own
  /// loopback, is handed it at once. So for every device but USB, a clock written ahead of time
  /// is held here until it is due, as WinMM's scheduler holds it on Windows. It still goes with
  /// its stamp, so a device that does keep to stamps loses nothing.
  ///
  /// A thread of its own waits on a condition for the next message's moment. `HostTime` is
  /// `CLOCK_MONOTONIC` in nanoseconds on Android, so a stamp is the wait's deadline as it stands.
  /// The thread asks for Android's urgent audio priority, which an app may give its own threads,
  /// and keeps to the big cores, as the render thread does. Measured on a Fairphone 6 with a beat
  /// of clock: left to the scheduler it sent 0.3 to 0.7ms late on average but now and then 5ms;
  /// kept to the big cores, 1 to 1.5ms late but never more than 2 — and a steady lateness is a
  /// constant a clock follower takes up, where a jumping one is a wobble in the tempo.
  /// What sending means is handed in, so the timing can be tested without a device.
  ///
  /// The thread holds the `Core` and nothing else, so letting go of the scheduler ends it.
  final class MIDIScheduler: Sendable {
    /// How late messages went out, in milliseconds after their stamps.
    struct Lateness: Sendable {
      var count: Int
      var least: Double
      var average: Double
      var most: Double
    }

    private let core: Core
    private let thread: Mutex<pthread_t?>

    /// Whether the thread got its priority, once it has started.
    var urgent: Bool { core.urgent.load(ordering: .acquiring) }

    /// How late messages went out since last asked, in milliseconds after their stamps, over
    /// `count` of them: how late the scheduler is, apart from anything after it.
    func takeLateness() -> Lateness {
      let count = core.sent.exchange(0, ordering: .acquiringAndReleasing)
      let total = core.totalLateness.exchange(0, ordering: .acquiringAndReleasing)
      let least = core.leastLateness.exchange(.max, ordering: .acquiringAndReleasing)
      let most = core.mostLateness.exchange(0, ordering: .acquiringAndReleasing)
      guard count > 0 else { return Lateness(count: 0, least: 0, average: 0, most: 0) }
      return Lateness(
        count: count, least: Double(least) / 1e6, average: Double(total) / Double(count) / 1e6,
        most: Double(most) / 1e6)
    }

    /// `deliver` is called on the scheduler's thread with each message as it falls due: where it
    /// is going, its bytes and its stamp.
    init(cores: [Int] = [], deliver: @escaping @Sendable (String, [UInt8], UInt64) -> Void) {
      core = Core(cores: cores, deliver: deliver)
      var made = pthread_t()
      let started = pthread_create(
        &made, nil,
        { context in
          guard let context else { return nil }
          Unmanaged<Core>.fromOpaque(context).takeRetainedValue().run()
          return nil
        }, Unmanaged.passRetained(core).toOpaque())
      thread = Mutex(started == 0 ? made : nil)
    }

    deinit { stop() }

    /// Send `bytes` to `destination` at `time`.
    func schedule(_ bytes: [UInt8], to destination: String, at time: UInt64) {
      core.locked { $0.add(bytes, to: destination, at: time) }
    }

    /// Forget whatever has not gone to `destination` yet.
    func drop(_ destination: String) {
      core.locked { $0.drop(destination) }
    }

    /// End the thread and wait for it, having sent nothing more. Once `stop` returns, `deliver`
    /// is not called again.
    func stop() {
      guard
        let running = thread.withLock({ thread in
          defer { thread = nil }
          return thread
        })
      else { return }
      core.stop()
      pthread_join(running, nil)
    }

    private final class Core: @unchecked Sendable {
      /// The lock and the condition the thread waits on, at addresses that do not move.
      private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
      private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
      /// Both only with `mutex` held.
      private var queue = MIDIQueue<[UInt8]>()
      private var running = true
      private let deliver: @Sendable (String, [UInt8], UInt64) -> Void
      /// The cores to keep to, as a CPU set; empty for any.
      private let cores: [UInt64]
      let urgent = Atomic<Bool>(false)
      /// Messages sent, and nanoseconds after their stamps: in all, at least and at most.
      let sent = Atomic<Int>(0)
      let totalLateness = Atomic<Int>(0)
      let leastLateness = Atomic<Int>(.max)
      let mostLateness = Atomic<Int>(0)

      init(cores: [Int], deliver: @escaping @Sendable (String, [UInt8], UInt64) -> Void) {
        self.deliver = deliver
        self.cores = cores.isEmpty ? [] : PerformanceCores.mask(cores)
        pthread_mutex_init(mutex, nil)
        var attributes = pthread_condattr_t()
        pthread_condattr_init(&attributes)
        pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)
        pthread_cond_init(condition, &attributes)
        pthread_condattr_destroy(&attributes)
      }

      deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
      }

      /// `change` done to the queue, and the thread woken to look at it again.
      func locked(_ change: (inout MIDIQueue<[UInt8]>) -> Void) {
        pthread_mutex_lock(mutex)
        change(&queue)
        pthread_cond_signal(condition)
        pthread_mutex_unlock(mutex)
      }

      func stop() {
        pthread_mutex_lock(mutex)
        running = false
        pthread_cond_signal(condition)
        pthread_mutex_unlock(mutex)
      }

      func run() {
        // Android's THREAD_PRIORITY_URGENT_AUDIO.
        urgent.store(setpriority(PRIO_PROCESS, id_t(gettid()), -19) == 0, ordering: .releasing)
        if !cores.isEmpty, let setAffinity = Bionic.setAffinity {
          _ = cores.withUnsafeBytes { setAffinity(0, $0.count, $0.baseAddress!) }
        }
        pthread_mutex_lock(mutex)
        while running {
          let due = queue.takeDue(at: HostTime.now())
          if !due.isEmpty {
            pthread_mutex_unlock(mutex)
            for item in due {
              deliver(item.destination, item.message, item.time)
              let late = Int(clamping: HostTime.now() &- item.time)
              sent.add(1, ordering: .relaxed)
              totalLateness.add(late, ordering: .relaxed)
              leastLateness.min(late, ordering: .relaxed)
              mostLateness.max(late, ordering: .relaxed)
            }
            pthread_mutex_lock(mutex)
            continue
          }
          if let next = queue.next {
            var until = timespec(tv_sec: Int(next / 1_000_000_000), tv_nsec: Int(next % 1_000_000_000))
            pthread_cond_timedwait(condition, mutex, &until)
          } else {
            pthread_cond_wait(condition, mutex)
          }
        }
        pthread_mutex_unlock(mutex)
      }
    }
  }
#endif
