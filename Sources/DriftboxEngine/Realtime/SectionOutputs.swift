/// Where each of a song's four machines goes, besides the song's own mix: the web engine's
/// `sectionOutputs`, a drum machine's individual outputs. The 808, the 909, 303 A and 303 B, in
/// that order, each a stereo pair of buffers the engine writes the machine's dry sound into —
/// panned and levelled, before the master and without its sends' returns.
///
/// Every machine's sound is written to its outputs whether or not it is diverted, so a host can
/// meter one nobody has patched; a diverted machine is also left out of the song's mix, so it is
/// heard only where the host sends it. Its delay and reverb sends stay the song's.
public struct SectionOutputs {
  /// The 808, the 909, 303 A and 303 B.
  public static var count: Int { 4 }

  /// Eight buffers, left then right for each machine in order, each at least as long as the
  /// render they are given to.
  public let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  /// Bit `n` set: machine `n` is left out of the song's mix.
  public var diverted: UInt8

  public init(buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, diverted: UInt8 = 0) {
    self.buffers = buffers
    self.diverted = diverted
  }

  /// The machine a voice belongs to, by its id: `808.*`, `909.*`, `303.a`, `303.b`, as the
  /// reference's `clipSlotForVoice` has them; -1 for anything else.
  public static func section(ofVoice id: String) -> Int8 {
    if id.hasPrefix("808.") { return 0 }
    if id.hasPrefix("909.") { return 1 }
    if id == "303.a" { return 2 }
    if id == "303.b" { return 3 }
    return -1
  }
}
