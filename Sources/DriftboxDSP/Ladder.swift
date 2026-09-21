/// A 4-pole transistor ladder filter: Huovilainen's model, 2x oversampled, with a tanh in each
/// stage so the saturation sits inside the feedback loop.
///
/// A line-for-line port of `driftbox/packages/engine/src/dsp/ladder.ts`, and the reasoning for
/// every constant lives there rather than being copied here to drift. State is `Double` because
/// the reference computes in doubles: JavaScript numbers are 64-bit whatever array they end up
/// stored in, and a filter with this much feedback turns a narrower intermediate into a
/// different sound.
public struct Ladder {
  var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0
  var prev3 = 0.0, feedback = 0.0
  var t0 = 0.0, t1 = 0.0, t2 = 0.0, t3 = 0.0

  public let sampleRate: Double

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  public mutating func reset() {
    self = Ladder(sampleRate: sampleRate)
  }

  /// One sample. `cutoff` in Hz, `resonance` 0...1, both read per sample because a 303's
  /// envelope is sweeping the cutoff on every note.
  @_noAllocation
  public mutating func process(_ input: Double, cutoff: Double, resonance: Double) -> Double {
    let nyquist = sampleRate * 0.5
    let clamped = cutoff < 20 ? 20 : cutoff > nyquist * 0.92 ? nyquist * 0.92 : cutoff
    let f = clamped / sampleRate / 2

    let f2 = f * f
    let f3 = f2 * f
    let fcr = 1.873 * f3 + 0.4955 * f2 - 0.649 * f + 0.9988
    let acr = -3.9364 * f2 + 1.8409 * f + 0.9968
    let tune = 1 - dbExp(-2 * Double.pi * f * fcr)

    let k = 4.8 * (resonance < 0 ? 0 : resonance > 1 ? 1 : resonance) * acr

    for _ in 0..<2 {
      let x = input - k * (feedback - 0.5 * input)

      let tx = dbTanh(x)
      s0 += tune * (tx - t0)
      t0 = dbTanh(s0)
      s1 += tune * (t0 - t1)
      t1 = dbTanh(s1)
      s2 += tune * (t1 - t2)
      t2 = dbTanh(s2)
      s3 += tune * (t2 - t3)

      feedback = (s3 + prev3) * 0.5
      prev3 = s3
      t3 = dbTanh(s3)
    }

    return s3
  }
}
