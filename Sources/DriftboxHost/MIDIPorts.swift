import DriftboxSeq

/// Every MIDI source a platform has, as the rest of Driftbox hears them. Notes go to `onNote`
/// (note number, velocity 0...1 — 0 is a release); clock messages, stamped in milliseconds, to
/// `onClock`; the list of sources, whenever a device comes or goes, to `onSourcesChange`. All
/// three may be called on any thread.
public protocol MIDIInputPort: AnyObject, Sendable {
  var onNote: (@Sendable (Int, Double) -> Void)? { get set }
  var onClock: (@Sendable (ClockMessage, Double) -> Void)? { get set }
  var onSourcesChange: (@Sendable ([String]) -> Void)? { get set }
  /// Every source there is, whether it is being listened to or not.
  var sources: [String] { get }
  /// Sources to hear nothing from, by name: a device unplugged and plugged back in comes back as
  /// something new with the same name, and what somebody chose to ignore was the device.
  var ignoring: Set<String> { get set }
}

/// Where MIDI bytes can be sent: one of the machine's destinations by name, or a source of
/// Driftbox's own that other software on the machine can listen to, where the platform has one.
public enum MIDIDestination: Hashable, Sendable {
  case virtual
  case port(String)
}

/// Bytes out, each stamped with the `HostTime` it belongs to rather than sent the moment it is
/// written, so a clock written ahead of time is played on time.
public protocol MIDIOutputPort: AnyObject, Sendable {
  /// Every destination there is.
  var destinations: [String] { get }
  /// Whether `.virtual` goes anywhere: whether the platform lets an application publish a source
  /// of its own.
  var offersVirtualSource: Bool { get }
  /// Hand one MIDI 1.0 message to `destination`, to be played at `hostTime`. False when it will
  /// go nowhere, which is what a destination unplugged since it was chosen looks like.
  @discardableResult
  func send(_ bytes: [UInt8], to destination: MIDIDestination, at hostTime: UInt64) -> Bool
  /// Drop whatever is still waiting to go to `destination`.
  func flush(_ destination: MIDIDestination)
}

/// What one MIDI 1.0 channel or system message means to Driftbox, however the platform delivered
/// its bytes: a note, a clock message, or nothing.
public enum MIDIMessage: Equatable, Sendable {
  case note(Int, velocity: Double)
  case clock(ClockMessage)

  public init?(status: UInt8, _ data1: UInt8, _ data2: UInt8) {
    if status >= 0xF0 {
      guard let clock = ClockMessage(bytes: [status, data1 & 0x7F, data2 & 0x7F]) else { return nil }
      self = .clock(clock)
      return
    }
    switch status & 0xF0 {
    case 0x90: self = .note(Int(data1 & 0x7F), velocity: Double(data2 & 0x7F) / 127)
    case 0x80: self = .note(Int(data1 & 0x7F), velocity: 0)
    default: return nil
    }
  }
}
