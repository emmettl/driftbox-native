import DriftboxEngine
import DriftboxSeq
import Synchronization

/// What the interface can ask the engine to do. Plain bytes, so a ring can carry it.
public enum Command {
  case play
  /// Play, counting in first if the engine is stopped and has a count-in set: what a person
  /// pressing play means. `play` is what an edit or an external clock means.
  case start
  case stop
  /// Loop `bars` bars from `startBar`; zero bars clears the loop.
  case loop(startBar: Int, bars: Int)
  case metronome(Bool)
  /// Bars of clicks before the song moves, when it is started from a stop.
  case countIn(bars: Int)
  case seek(songFrame: Int)
  /// Play this song from its start. The engine hands back the song it was playing through the
  /// `released` ring, for the sender to free.
  case load(UnsafeMutablePointer<CompiledSong>?)
  case pad(x: Double, y: Double)
  case padRelease
  /// Strike a voice now, outside the song: the keys. Prepared against time zero; the engine
  /// places it on the next frame it renders.
  case strike(FixedVoiceSpec)
  /// Play a 303 note now, on line 0 or 1.
  case note(line: Int, BassNote)
}

/// A single-producer, single-consumer ring of commands: the interface writes, the render thread
/// reads, and neither waits for the other. Fixed capacity; a full ring drops the newest command
/// and says so.
///
/// Lives behind a pointer, never copied, so the atomics inside it stay where they are.
public struct CommandRing: ~Copyable {
  public static var capacity: Int { 64 }

  let slots: UnsafeMutablePointer<Command>
  let head = Atomic<Int>(0)
  let tail = Atomic<Int>(0)

  public init() {
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: .stop, count: Self.capacity)
  }

  deinit {
    slots.deallocate()
  }

  /// From the producer. False if the ring was full.
  @discardableResult
  public func send(_ command: Command) -> Bool {
    let write = tail.load(ordering: .relaxed)
    let read = head.load(ordering: .acquiring)
    if write - read >= Self.capacity { return false }
    slots[write % Self.capacity] = command
    tail.store(write + 1, ordering: .releasing)
    return true
  }

  /// From the consumer. Nil when there is nothing waiting.
  @_noAllocation
  public func receive() -> Command? {
    let read = head.load(ordering: .relaxed)
    let write = tail.load(ordering: .acquiring)
    if read == write { return nil }
    let command = slots[read % Self.capacity]
    head.store(read + 1, ordering: .releasing)
    return command
  }
}

/// A ring of songs the engine has finished with, for whoever loaded them to free.
public struct ReleaseRing: ~Copyable {
  public static var capacity: Int { 16 }
  let slots: UnsafeMutablePointer<UnsafeMutablePointer<CompiledSong>?>
  let head = Atomic<Int>(0)
  let tail = Atomic<Int>(0)

  public init() {
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: nil, count: Self.capacity)
  }

  deinit {
    slots.deallocate()
  }

  @_noAllocation
  public func send(_ song: UnsafeMutablePointer<CompiledSong>) {
    let write = tail.load(ordering: .relaxed)
    let read = head.load(ordering: .acquiring)
    // A full ring leaks the song rather than freeing it on the render thread.
    if write - read >= Self.capacity { return }
    slots[write % Self.capacity] = song
    tail.store(write + 1, ordering: .releasing)
  }

  public func receive() -> UnsafeMutablePointer<CompiledSong>? {
    let read = head.load(ordering: .relaxed)
    let write = tail.load(ordering: .acquiring)
    if read == write { return nil }
    let song = slots[read % Self.capacity]
    head.store(read + 1, ordering: .releasing)
    return song
  }
}
