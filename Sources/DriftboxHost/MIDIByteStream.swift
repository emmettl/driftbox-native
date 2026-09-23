/// MIDI 1.0 as a port delivers it, a stream of bytes, made back into whole messages.
///
/// CoreMIDI hands the Mac whole messages and WinMM hands Windows one at a time, but Android hands
/// over packets of bytes as they came off the wire, where one message can follow another with its
/// status byte left out, a clock tick can land in the middle of a note, and system exclusive can
/// run on for as long as it likes. This is the wire's own rules, kept per source across packets.
public struct MIDIByteStream: Sendable {
  /// The status the next data bytes belong to, which stays for as long as channel messages keep
  /// leaving it out: running status. 0 for none.
  private var status: UInt8 = 0
  private var first: UInt8 = 0
  private var have = 0
  private var inExclusive = false

  public init() {}

  /// `bytes`, as whole messages of one to three bytes, each handed to `message` as it completes.
  /// Real-time messages come out the moment they arrive, even from the middle of another.
  /// System exclusive is skipped, and data with no status to belong to is dropped.
  public mutating func feed(_ bytes: some Sequence<UInt8>, _ message: ([UInt8]) -> Void) {
    for byte in bytes {
      switch byte {
      case 0xF8...0xFF:
        message([byte])
      case 0xF0:
        inExclusive = true
        status = 0
      case 0xF7:
        inExclusive = false
        status = 0
      case 0x80...0xF6:
        inExclusive = false
        have = 0
        if Self.length(of: byte) == 0 {
          status = 0
          message([byte])
        } else {
          status = byte
        }
      default:
        guard !inExclusive, status != 0 else { continue }
        if have == 0 && Self.length(of: status) == 2 {
          first = byte
          have = 1
          continue
        }
        message(have == 0 ? [status, byte] : [status, first, byte])
        have = 0
        // System common messages have no running status; only channel messages carry on.
        if status >= 0xF0 { status = 0 }
      }
    }
  }

  /// How many data bytes follow `status`.
  private static func length(of status: UInt8) -> Int {
    switch status {
    case 0xC0...0xDF, 0xF1, 0xF3: return 1
    case 0x80...0xEF, 0xF2: return 2
    default: return 0
    }
  }
}
