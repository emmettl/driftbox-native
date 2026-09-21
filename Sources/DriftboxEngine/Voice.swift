import DriftboxSeq

public enum Machine: Equatable, Sendable {
  case tr808, tr909
}

/// A voice is a name, a machine, and the pure function from knobs to sound.
public struct Voice: Sendable {
  public var id: String
  public var name: String
  public var machine: Machine
  /// Voices that share a choke group cut each other off: a closed hat silences a ringing open
  /// one, as on the hardware, where the two share a circuit.
  public var choke: String?
  /// Output normalisation. Every voice sums a different number of sources, so their natural peaks
  /// land all over the place; these bring them to roughly the same level, so the musical balance
  /// is set by the level knobs and not by accident. Measured on the reference, not guessed.
  public var trim: Double?
  /// The fundamental the tune knob covers, in Hz, where that knob is a pitch.
  public var pitched: ClosedRange<Double>?
  var builder: @Sendable (VoiceParams, Double) -> VoiceSpec

  /// The spec for one hit, with the voice's trim applied. Everything that turns a voice into
  /// sound goes through here, so a drawn waveform and an audible hit cannot disagree.
  public func build(_ params: VoiceParams = VoiceParams(), accent: Double) -> VoiceSpec {
    var spec = builder(params, accent)
    if let trim { spec.trim = trim }
    return spec
  }
}

/// Both machines, in the reference's order: the 909 first.
public let allVoices: [Voice] = tr909Voices + tr808Voices

public func voice(id: String) -> Voice? {
  allVoices.first { $0.id == id }
}

// MARK: - What the builders share

/// Accent is not just louder: the higher trigger voltage drives the envelope circuit harder.
func accentGain(_ params: VoiceParams, _ accent: Double) -> Double {
  range(params.level, 0, 1) * (0.62 + 0.38 * accent)
}

/// The metallic source both machines use for hats and cymbals: six squares at deliberately
/// inharmonic ratios, which never line up into a harmonic series, so the ear refuses to hear a
/// pitch. The ratios are the well-known 808 set.
let metallicRatios = [2, 3, 4.16, 5.43, 6.79, 8.21]

func metallicSources(base: Double, gain: Double, amp: [Breakpoint]) -> [Source] {
  metallicRatios.map {
    Source(.oscillator(Oscillator(type: .square, frequency: base * $0)), gain: gain, amp: amp)
  }
}

/// An attack and a decay: how nearly every source's amplitude is written.
func strike(attack: Double, decay: Double) -> [Breakpoint] {
  [Breakpoint(to: 1, at: attack, curve: .linear), Breakpoint(to: 0, at: decay)]
}
