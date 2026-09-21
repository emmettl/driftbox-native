import DriftboxDSP
import DriftboxEngine
import DriftboxSeq
import Synchronization

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

  /// What the render thread last reported: where the song is, and whether it is playing.
  public let songFrame = Atomic<Int>(-1)
  public let engineFrame = Atomic<Int>(0)
  public let playing = Atomic<Bool>(false)

  public init(sampleRate: Double, voiceCapacity: Int = 32) {
    self.sampleRate = sampleRate
    engine = .allocate(capacity: 1)
    engine.initialize(to: SongEngine(sampleRate: sampleRate, voiceCapacity: voiceCapacity))
    commands = .allocate(capacity: 1)
    commands.initialize(to: CommandRing())
    released = .allocate(capacity: 1)
    released.initialize(to: ReleaseRing())
  }

  deinit {
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

  // MARK: - From the render thread

  /// Everything the render callback does: take what the interface asked for, then render.
  @_noAllocation
  public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
    while let command = commands.pointee.receive() {
      switch command {
      case .play: engine.pointee.play()
      case .stop: engine.pointee.stop()
      case .seek(let frame): engine.pointee.seek(toSongFrame: frame)
      case .load(let song):
        let previous = engine.pointee.song
        engine.pointee.load(song)
        if let previous { released.pointee.send(previous) }
      case .pad(let x, let y): engine.pointee.pad.set(x: x, y: y, atFrame: engine.pointee.frame)
      case .padRelease: engine.pointee.pad.release(atFrame: engine.pointee.frame)
      }
    }
    engine.pointee.render(frames: frames, left: left, right: right)
    songFrame.store(engine.pointee.songFrame(), ordering: .relaxed)
    engineFrame.store(engine.pointee.frame, ordering: .relaxed)
    playing.store(engine.pointee.isPlaying, ordering: .relaxed)
  }
}
