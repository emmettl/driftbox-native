import DriftboxDSP
import DriftboxSeq

/// The performance filter: a Kaoss-pad-style XY insert across the whole mix. Across is cutoff, up
/// is resonance. A port of `driftbox/packages/engine/src/kaoss.ts`.
///
/// It filters everything, not just the 303s — the fun of one of these is that the whole record
/// ducks away and comes back, drums included — and it sits after the bus compressor, so the
/// compressor is not reacting to signal the filter is about to throw away.
///
/// It is a low-pass into a high-pass. Left of centre sweeps the low-pass down; right of centre
/// sweeps the high-pass up; in the middle both are wide open. **Wide open is not absent.** Two
/// biquads at the edges of the band still turn the phase of the bass and shave the very top:
/// measured in the reference, the idle pad's output differs from its input, sample for sample, by
/// almost the whole signal. Nobody hears that — it is phase — but every mix the reference renders
/// has been through it, so every mix here goes through it too.
public struct Kaoss {
  static let neutral = 0.5
  /// Below about 80Hz there is nothing left to hear and the pad's corner is dead travel.
  static let lowFloor = 90.0
  static let lowCeiling = 20000.0
  static let highFloor = 20.0
  /// Past about 6kHz only cymbals survive, which is the point; further is just silence.
  static let highCeiling = 6000.0
  /// Enough to whistle on a sweep, short of what clips the master on its own.
  static let maximumQ = 12.0
  /// A floor rather than zero, so the idle filter is damped rather than undefined.
  static let minimumQ = 0.0001

  public let sampleRate: Double
  /// Whether the pad is being held. An interface wants to know, to draw itself.
  public private(set) var isActive = false

  var lowpassLeft: Biquad
  var lowpassRight: Biquad
  var highpassLeft: Biquad
  var highpassRight: Biquad
  var lowFrequency: TargetSmoother
  var highFrequency: TargetSmoother
  var lowQ: TargetSmoother
  var highQ: TargetSmoother

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    lowpassLeft = Biquad(response: .lowpass, sampleRate: sampleRate)
    lowpassRight = Biquad(response: .lowpass, sampleRate: sampleRate)
    highpassLeft = Biquad(response: .highpass, sampleRate: sampleRate)
    highpassRight = Biquad(response: .highpass, sampleRate: sampleRate)
    lowFrequency = TargetSmoother(value: Float(Self.lowCeiling), sampleRate: sampleRate)
    highFrequency = TargetSmoother(value: Float(Self.highFloor), sampleRate: sampleRate)
    lowQ = TargetSmoother(value: Float(Self.minimumQ), sampleRate: sampleRate)
    highQ = TargetSmoother(value: Float(Self.minimumQ), sampleRate: sampleRate)
  }

  /// Where a horizontal position puts each filter. Exponential either side of centre, because
  /// cutoff is heard as a ratio and a linear sweep spends most of its travel doing nothing.
  public static func cutoffs(x: Double) -> (low: Double, high: Double) {
    let x = max(0, min(1, x))
    return (
      x < neutral ? ratioRange(x / neutral, lowFloor, lowCeiling) : lowCeiling,
      x > neutral ? ratioRange((x - neutral) / (1 - neutral), highFloor, highCeiling) : highFloor
    )
  }

  public static func resonance(y: Double) -> Double {
    minimumQ + max(0, min(1, y)) * (maximumQ - minimumQ)
  }

  /// Move the filter. `x` and `y` are 0...1 from the pad's bottom-left.
  ///
  /// Everything glides rather than jumps. A pointer reports sixty times a second, and stepping a
  /// resonant filter's cutoff that often is a zipper — the one artefact that would make this feel
  /// cheap rather than expensive.
  public mutating func set(x: Double, y: Double, glide: Double = 0.02, atFrame frame: Int) {
    let x = max(0, min(1, x))
    let (low, high) = Self.cutoffs(x: x)
    lowFrequency.setTarget(Float(low), at: frame, timeConstant: glide)
    highFrequency.setTarget(Float(high), at: frame, timeConstant: glide)
    // Resonance only on whichever filter is doing something. On both, the idle one rings at the
    // edge of the band and adds a permanent whistle.
    let q = Self.resonance(y: y)
    lowQ.setTarget(Float(x < Self.neutral ? q : Self.minimumQ), at: frame, timeConstant: glide)
    highQ.setTarget(Float(x > Self.neutral ? q : Self.minimumQ), at: frame, timeConstant: glide)
    isActive = true
  }

  /// Let go. Momentary rather than latching, deliberately: a filter left half-shut after a finger
  /// lifts sounds like something is broken.
  public mutating func release(glide: Double = 0.12, atFrame frame: Int) {
    lowFrequency.setTarget(Float(Self.lowCeiling), at: frame, timeConstant: glide)
    highFrequency.setTarget(Float(Self.highFloor), at: frame, timeConstant: glide)
    lowQ.setTarget(Float(Self.minimumQ), at: frame, timeConstant: glide)
    highQ.setTarget(Float(Self.minimumQ), at: frame, timeConstant: glide)
    isActive = false
  }

  /// One stereo frame through the pad. Call once per frame, in order.
  public mutating func process(left: Float, right: Float, frame: Int) -> (left: Float, right: Float) {
    let lowHertz = Double(lowFrequency.next(frame: frame))
    let lowResonance = Double(lowQ.next(frame: frame))
    let highHertz = Double(highFrequency.next(frame: frame))
    let highResonance = Double(highQ.next(frame: frame))
    lowpassLeft.set(frequency: lowHertz, q: lowResonance)
    lowpassRight.set(frequency: lowHertz, q: lowResonance)
    highpassLeft.set(frequency: highHertz, q: highResonance)
    highpassRight.set(frequency: highHertz, q: highResonance)
    // What passes between two of the browser's nodes is single precision.
    let betweenLeft = Float(lowpassLeft.process(Double(left)))
    let betweenRight = Float(lowpassRight.process(Double(right)))
    return (
      Float(highpassLeft.process(Double(betweenLeft))), Float(highpassRight.process(Double(betweenRight)))
    )
  }
}
