#if os(Windows)
  import CWASAPI
  import DriftboxHost
  import Foundation
  import Synchronization
  import WinSDK

  /// Messages held until the moment they are stamped with, then sent.
  ///
  /// CoreMIDI takes a timestamp with every message and plays it then; WinMM sends whatever it is
  /// given at once. A clock written a fifth of a second ahead, as `ClockCursor` writes it, needs
  /// something in between, and this is it: a thread of its own, at the audio's priority, asleep on
  /// a high-resolution timer until the next message is due. What sending means is handed in, so
  /// the timing can be tested without a device.
  ///
  /// The thread holds the `Core` and nothing else, so letting go of the scheduler is what ends it.
  final class MIDIScheduler: Sendable {
    struct Item {
      var time: UInt64
      var destination: String
      var message: UInt32
    }

    private let core: Core

    init(deliver: @escaping @Sendable (String, UInt32) -> Void) {
      core = Core(deliver: deliver)
      let thread = Thread { [core] in core.run() }
      thread.name = "Driftbox MIDI out"
      thread.start()
    }

    deinit { core.stop() }

    /// Send `message` to `destination` at `time`.
    func schedule(_ message: UInt32, to destination: String, at time: UInt64) {
      core.queue.withLock { items in
        // Stamps arrive in order almost always, so the place for one is nearly always the end.
        let at = items.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
        items.insert(Item(time: time, destination: destination, message: message), at: at)
      }
      SetEvent(core.wake)
    }

    /// Forget whatever has not gone to `destination` yet.
    func drop(_ destination: String) {
      core.queue.withLock { $0.removeAll { $0.destination == destination } }
    }

    private final class Core: @unchecked Sendable {
      let queue = Mutex<[Item]>([])
      private let running = Atomic<Bool>(true)
      /// Handles, made once and closed once the thread has finished with them.
      let wake: HANDLE?
      private let timer: HANDLE?
      private let finished = DispatchSemaphore(value: 0)
      private let deliver: @Sendable (String, UInt32) -> Void

      init(deliver: @escaping @Sendable (String, UInt32) -> Void) {
        self.deliver = deliver
        wake = CreateEventW(nil, false, false, nil)
        // A high-resolution timer is good to half a millisecond; the ordinary kind only to the
        // scheduler's tick, which is most of the gap between two ticks of a clock at 120.
        let highResolution: DWORD = 0x2  // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
        let access: DWORD = 0x1F_0003  // TIMER_ALL_ACCESS
        timer =
          CreateWaitableTimerExW(nil, nil, highResolution, access)
          ?? CreateWaitableTimerExW(nil, nil, 0, access)
      }

      func stop() {
        running.store(false, ordering: .releasing)
        SetEvent(wake)
        finished.wait()
        CloseHandle(wake)
        CloseHandle(timer)
      }

      func run() {
        var task: DWORD = 0
        let priority = "Pro Audio".withCString(encodedAs: UTF16.self) {
          AvSetMmThreadCharacteristicsW($0, &task)
        }
        defer {
          if let priority { AvRevertMmThreadCharacteristics(priority) }
          finished.signal()
        }
        var handles: [HANDLE?] = [wake, timer]
        while running.load(ordering: .acquiring) {
          let now = HostTime.now()
          let (due, next) = queue.withLock { items -> ([Item], UInt64?) in
            let count = items.firstIndex { $0.time > now } ?? items.count
            let due = Array(items[..<count])
            items.removeFirst(count)
            return (due, items.first?.time)
          }
          for item in due { deliver(item.destination, item.message) }
          if let next {
            // Relative, in hundreds of nanoseconds, which the timer takes as a negative number.
            var dueTime = LARGE_INTEGER()
            dueTime.QuadPart = -max(1, Int64(HostTime.seconds(from: HostTime.now(), to: next) * 10_000_000))
            SetWaitableTimer(timer, &dueTime, 0, nil, nil, false)
            _ = handles.withUnsafeMutableBufferPointer {
              WaitForMultipleObjects(2, $0.baseAddress, false, INFINITE)
            }
          } else {
            WaitForSingleObject(wake, INFINITE)
          }
        }
      }
    }
  }
#endif
