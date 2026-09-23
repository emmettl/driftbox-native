/// MIDI messages waiting for the moment they are stamped with, in the order of their stamps.
///
/// Where a platform sends whatever it is given at once — WinMM on Windows, and another app on
/// Android — a clock written ahead of time has to be held back until it is due, and each
/// platform's scheduler waits for that moment in its own way. What is waited for is the same
/// everywhere, and is this: kept under the scheduler's lock, it says what is due and when the
/// next thing will be.
public struct MIDIQueue<Message: Sendable>: Sendable {
  public struct Item: Sendable {
    public var time: UInt64
    public var destination: String
    public var message: Message
  }

  private var items: [Item] = []

  public init() {}

  /// When the first thing waiting is due; nil if nothing is.
  public var next: UInt64? { items.first?.time }

  /// `message` for `destination` at `time`, after anything already waiting for the same moment.
  public mutating func add(_ message: Message, to destination: String, at time: UInt64) {
    // Stamps arrive in order almost always, so the place for one is nearly always the end.
    let at = items.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
    items.insert(Item(time: time, destination: destination, message: message), at: at)
  }

  /// Everything waiting for `destination`, forgotten.
  public mutating func drop(_ destination: String) {
    items.removeAll { $0.destination == destination }
  }

  /// Everything due by `now`, in order, taken out.
  public mutating func takeDue(at now: UInt64) -> [Item] {
    let count = items.firstIndex { $0.time > now } ?? items.count
    defer { items.removeFirst(count) }
    return Array(items[..<count])
  }
}
