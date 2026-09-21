// The TB-303, as data. A port of `driftbox/packages/engine/src/bass.ts`: a pure function from the
// panel and a step to a description of one note. What makes a line sound like a 303 is how the
// notes relate to each other, which is why it takes the previous step too.

public enum BassWave: Equatable, Sendable {
  case sawtooth, square
}

/// One note, ready to be played. Frequencies in Hz, times in seconds.
public struct BassNote: Equatable, Sendable {
  public var frequency: Double
  /// Seconds to glide from the previous stored pitch. 0 means the note starts on pitch.
  public var glide: Double
  /// Where a glide starts, including a pitch authored on a silent step.
  public var glideFrom: Double?
  /// False when sliding out of a sounding note: two notes sharing one attack is what a slide is.
  public var retrigger: Bool
  /// How long the note is held before its release.
  public var gate: Double
  public var wave: BassWave
  public var gain: Double
  public var resonance: Double
  /// Where the filter sweep starts, where it settles, and how fast.
  public var filterPeak: Double
  public var filterBase: Double
  public var filterDecay: Double

  public init(
    frequency: Double, glide: Double, glideFrom: Double? = nil, retrigger: Bool, gate: Double, wave: BassWave,
    gain: Double, resonance: Double, filterPeak: Double, filterBase: Double, filterDecay: Double
  ) {
    self.frequency = frequency
    self.glide = glide
    self.glideFrom = glideFrom
    self.retrigger = retrigger
    self.gate = gate
    self.wave = wave
    self.gain = gain
    self.resonance = resonance
    self.filterPeak = filterPeak
    self.filterBase = filterBase
    self.filterDecay = filterDecay
  }
}

/// The 303's slide time. Fixed on the hardware, and short enough to read as a lean into the next
/// note rather than as portamento.
public let slideSeconds = 0.055

private let rootHz = 55.0
/// A resonant peak up near Nyquist is not brightness, it is aliasing.
private let cutoffCeiling = 11000.0

/// The note for `step`, given what came before it. Nil for a step that does not sound.
public func bassNote(
  params: BassParams, step: BassStep, previous: BassStep, stepSeconds: Double
) -> BassNote? {
  guard step.sounds, let pitch = step.note else { return nil }

  let root = ratioRange(params.tune, rootHz / 2, rootHz * 2)
  let frequency = root * seqPow(2, pitch / 12)

  // A paused step still owns its pitch: its slide bends the next attack from that silent pitch.
  // Only a sounding predecessor also suppresses the retrigger.
  let glidingIn = previous.slide && previous.note != nil
  let slidingIn = glidingIn && previous.sounds
  let accent = step.accent ? range(params.accent, 0.15, 1) : 0

  let base = ratioRange(params.cutoff, 90, 4200)
  let peak = min(cutoffCeiling, base * (1 + range(params.envMod, 0, 1) * 7 + accent * 5))

  return BassNote(
    frequency: frequency,
    glide: glidingIn ? slideSeconds : 0,
    glideFrom: glidingIn ? root * seqPow(2, (previous.note ?? 0) / 12) : nil,
    retrigger: !slidingIn,
    gate: stepSeconds * (step.slide ? 1.05 : 0.52),
    wave: params.wave < 0.5 ? .sawtooth : .square,
    gain: range(params.level, 0, 1) * (0.62 + 0.38 * accent),
    resonance: min(1, range(params.resonance, 0, 1) + accent * 0.12),
    filterPeak: peak,
    filterBase: base,
    filterDecay: ratioRange(params.decay, 0.05, 1.4)
  )
}

/// The step before `index`, wrapping at the bar — a line's first note slides out of its last when
/// it loops, which is how a one-bar acid pattern keeps moving.
public func previousStep(_ steps: [BassStep], index: Int, length: Int) -> BassStep {
  guard length > 0 else { return .rest }
  let at = wrap(index - 1, length)
  return at < steps.count ? steps[at] : .rest
}
