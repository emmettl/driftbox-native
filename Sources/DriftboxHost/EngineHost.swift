import DriftboxDSP
import DriftboxEngine
import DriftboxSeq
import Synchronization

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#elseif canImport(Android)
  import Android
#else
  import Glibc
#endif

/// The engine, its command ring, and the rule for who owns what: everything a render callback
/// needs, behind one pointer, with nothing for the callback to retain.
///
/// The interface talks to it through `send`; the render thread calls `render`, which first drains
/// the ring. Songs go in as pointers the interface made and come back out through `collect` when
/// the engine has let go of them.
public final class EngineHost: @unchecked Sendable {
  public let sampleRate: Double
  let engine: UnsafeMutablePointer<SongEngine>
  let commands: UnsafeMutablePointer<CommandRing>
  let released: UnsafeMutablePointer<ReleaseRing>
  /// Songs handed to the engine and not yet handed back.
  private var owned: [UnsafeMutablePointer<CompiledSong>] = []
  private let lock = Mutex<Void>(())

  /// How long the last second's render calls took, in nanoseconds of the render thread's own
  /// time: the sum, the longest, and how many. Reset by whoever reads them with `takeLoad`.
  let renderNanoseconds = Atomic<Int>(0)
  let longestNanoseconds = Atomic<Int>(0)
  let renderCalls = Atomic<Int>(0)
  let renderedFrames = Atomic<Int>(0)

  /// The loudest sample of the last render call, each side, as float bits — what a scene reads
  /// to breathe with the music without any analysis on the render thread.
  public let peakLeft = Atomic<UInt32>(0)
  public let peakRight = Atomic<UInt32>(0)

  /// What the render thread last reported: where the song is, and whether it is playing.
  public let songFrame = Atomic<Int>(-1)
  public let engineFrame = Atomic<Int>(0)
  public let playing = Atomic<Bool>(false)
  /// Whether the song is waiting on a count-in.
  public let countingIn = Atomic<Bool>(false)

  /// The last `monitorFrames` frames of the mix, mono, for a scene's spectrum: the render thread
  /// writes them after each call and `recentMix` copies them out. No lock — a frame that is
  /// half-written when it is read is a frame of visuals, not of audio.
  public static let monitorFrames = 4096
  let monitor: UnsafeMutablePointer<Float>
  let monitorWritten = Atomic<Int>(0)

  /// An engine at `sampleRate`, its clock starting at `clock`: zero for a new one, or the frame an
  /// engine playing a performance again should stand at, to run on the clock it was played on.
  public init(sampleRate: Double, voiceCapacity: Int = 32, clock: Int = 0) {
    self.sampleRate = sampleRate
    monitor = .allocate(capacity: Self.monitorFrames)
    monitor.initialize(repeating: 0, count: Self.monitorFrames)
    engine = .allocate(capacity: 1)
    engine.initialize(to: SongEngine(sampleRate: sampleRate, voiceCapacity: voiceCapacity))
    engine.pointee.startClock(at: clock)
    engineFrame.store(engine.pointee.frame, ordering: .relaxed)
    commands = .allocate(capacity: 1)
    commands.initialize(to: CommandRing())
    released = .allocate(capacity: 1)
    released.initialize(to: ReleaseRing())
  }

  deinit {
    monitor.deallocate()
    engine.deinitialize(count: 1)
    engine.deallocate()
    commands.deinitialize(count: 1)
    commands.deallocate()
    released.deinitialize(count: 1)
    released.deallocate()
    for song in owned {
      song.deinitialize(count: 1)
      song.deallocate()
    }
  }

  public var preparer: HitPreparer { engine.pointee.voices.preparer }

  /// The next thing the engine reports having played, from the interface's thread only.
  public func nextEvent() -> EngineEvent? {
    engine.pointee.events.receive()
  }

  /// How many frames of the mix have ever been written, so a reader can tell whether anything
  /// has arrived since it last looked.
  public var mixWritten: Int { monitorWritten.load(ordering: .acquiring) }

  /// The most recent `count` frames of the mix, oldest first, into `out`. At most
  /// `monitorFrames`.
  public func recentMix(_ count: Int, into out: UnsafeMutablePointer<Float>) {
    let count = min(count, Self.monitorFrames)
    let end = monitorWritten.load(ordering: .acquiring)
    var at = ((end - count) % Self.monitorFrames + Self.monitorFrames) % Self.monitorFrames
    for index in 0..<count {
      out[index] = monitor[at]
      at += 1
      if at == Self.monitorFrames { at = 0 }
    }
  }

  // MARK: - From the interface

  /// Compile `song` and ask the engine to play it. Songs it has finished with are freed here too.
  public func load(_ song: Song) {
    collect()
    let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
    compiled.initialize(to: CompiledSong(song, preparer: preparer))
    lock.withLock { _ in owned.append(compiled) }
    commands.pointee.send(.load(compiled))
  }

  public func send(_ command: Command) {
    commands.pointee.send(command)
  }

  /// Free whatever the engine has handed back.
  public func collect() {
    while let song = released.pointee.receive() {
      lock.withLock { _ in owned.removeAll { $0 == song } }
      song.deinitialize(count: 1)
      song.deallocate()
    }
  }

  /// The render thread's load since last asked: what fraction of the audio it rendered it spent
  /// rendering, and the longest single call in milliseconds.
  public func takeLoad() -> (fraction: Double, longestMilliseconds: Double, calls: Int) {
    let nanoseconds = renderNanoseconds.exchange(0, ordering: .relaxed)
    let frames = renderedFrames.exchange(0, ordering: .relaxed)
    let calls = renderCalls.exchange(0, ordering: .relaxed)
    let longest = longestNanoseconds.exchange(0, ordering: .relaxed)
    let audioSeconds = Double(frames) / sampleRate
    return (audioSeconds > 0 ? Double(nanoseconds) / 1e9 / audioSeconds : 0, Double(longest) / 1e6, calls)
  }

  // MARK: - From the render thread

  /// The calling thread's own CPU time. Vouched for by hand: a system call the checker cannot see into.
  @_semantics("no_performance_analysis") @inline(never)
  private func threadNanoseconds() -> UInt64 {
    #if canImport(Darwin)
      return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    #elseif os(Windows)
      // Wall time on the performance counter. Windows keeps a thread's own time only to the
      // scheduler's tick, 15.6ms, which is longer than a whole render call; and a render thread
      // at Pro Audio priority is seldom off the processor, so its wall time is near enough its own.
      return UInt64(Double(HostTime.now()) / HostTime.ticksPerSecond * 1e9)
    #else
      var spec = timespec()
      clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
      return UInt64(spec.tv_sec) * 1_000_000_000 + UInt64(spec.tv_nsec)
    #endif
  }

  /// Everything the render callback does: take what the interface asked for, then render.
  @_noAllocation
  public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
    render(frames: frames, left: left, right: right, sections: nil)
  }

  /// The same, with each of the song's machines into `sections` as well: the rack's way in.
  @_noAllocation
  public func render(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
    sections: SectionOutputs?
  ) {
    let began = threadNanoseconds()
    defer {
      let took = Int(threadNanoseconds() &- began)
      renderNanoseconds.add(took, ordering: .relaxed)
      renderCalls.add(1, ordering: .relaxed)
      renderedFrames.add(frames, ordering: .relaxed)
      longestNanoseconds.max(took, ordering: .relaxed)
    }
    while let command = commands.pointee.receive() {
      switch command {
      case .play: engine.pointee.play()
      case .start: engine.pointee.start()
      case .stop: engine.pointee.stop()
      case .loop(let startBar, let bars): engine.pointee.setLoop(startBar: startBar, bars: bars)
      case .metronome(let on): engine.pointee.metronome = on
      case .countIn(let bars): engine.pointee.countInBars = max(0, bars)
      case .seek(let frame): engine.pointee.seek(toSongFrame: frame)
      case .load(let song):
        let previous = engine.pointee.song
        engine.pointee.load(song)
        if let previous { released.pointee.send(previous) }
      case .pad(let x, let y): engine.pointee.pad.set(x: x, y: y, atFrame: engine.pointee.frame)
      case .padRelease: engine.pointee.pad.release(atFrame: engine.pointee.frame)
      case .strike(let hit): engine.pointee.strike(hit)
      case .note(let line, let note): engine.pointee.play(note, line: line)
      }
    }
    engine.pointee.render(frames: frames, left: left, right: right, sections: sections)
    var loudestLeft: Float = 0
    var loudestRight: Float = 0
    for index in 0..<frames {
      loudestLeft = max(loudestLeft, abs(left[index]))
      loudestRight = max(loudestRight, abs(right[index]))
    }
    peakLeft.store(loudestLeft.bitPattern, ordering: .relaxed)
    peakRight.store(loudestRight.bitPattern, ordering: .relaxed)
    var written = monitorWritten.load(ordering: .relaxed)
    var at = written % Self.monitorFrames
    for index in 0..<frames {
      monitor[at] = (left[index] + right[index]) * 0.5
      at += 1
      if at == Self.monitorFrames { at = 0 }
    }
    written += frames
    monitorWritten.store(written, ordering: .releasing)
    songFrame.store(engine.pointee.songFrame(), ordering: .relaxed)
    engineFrame.store(engine.pointee.frame, ordering: .relaxed)
    playing.store(engine.pointee.isPlaying, ordering: .relaxed)
    countingIn.store(engine.pointee.countInLeft > 0, ordering: .relaxed)
  }
}
