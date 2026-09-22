/// What the engine just played, for anything that wants to react to it: a drum hit, a 303 note,
/// the start of a pass. Plain bytes with a frame stamp, written by the render thread and read by
/// the interface. A full ring drops the oldest.
public struct EngineEvent {
  public enum Kind: UInt8 {
    case hit, note, pass
  }

  public var kind: Kind
  /// The engine's frame the event is due on.
  public var frame: Int
  /// For a hit: which voice, as its index in `allVoices`; for a note: 0 for 303 A, 1 for B.
  public var voice: Int
  /// A hit's accent, 0.55 or 1; a note's gain.
  public var level: Float
  /// A note's pitch in Hz; 0 for a hit.
  public var frequency: Float
  /// A hit's choke group; a note's slide flag as 1.
  public var flag: UInt8

  @_noAllocation
  public init(kind: Kind, frame: Int, voice: Int, level: Float, frequency: Float, flag: UInt8) {
    self.kind = kind
    self.frame = frame
    self.voice = voice
    self.level = level
    self.frequency = frequency
    self.flag = flag
  }
}

/// A ring the render thread writes without waiting. The reader takes what has arrived since it
/// last looked. Single producer, single consumer, and the counters are plain integers because
/// the two only ever move one of them each — a read that races a write sees either the old
/// count or the new, and both are safe.
public struct EventRing: ~Copyable {
  public static var capacity: Int { 1024 }
  let capacity = 1024
  let slots: UnsafeMutablePointer<EngineEvent>
  var written = 0
  var read = 0

  public init() {
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(
      repeating: EngineEvent(kind: .pass, frame: 0, voice: 0, level: 0, frequency: 0, flag: 0),
      count: Self.capacity)
  }

  deinit {
    slots.deallocate()
  }

  @_noAllocation
  public mutating func send(_ event: EngineEvent) {
    slots[written % capacity] = event
    written += 1
  }

  /// The next event not yet taken, or nil. Events overwritten before they were read are lost.
  public mutating func receive() -> EngineEvent? {
    if written - read > Self.capacity { read = written - Self.capacity }
    guard read < written else { return nil }
    let event = slots[read % Self.capacity]
    read += 1
    return event
  }
}
