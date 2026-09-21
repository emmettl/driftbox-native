/// A two-pole, two-zero filter with the Web Audio `BiquadFilterNode`'s responses.
///
/// The coefficients are the specification's, so a filter described for the browser sounds the
/// same here. Note what `q` means: for the low-pass and high-pass it is the resonance **in
/// decibels**, and for the band-pass it is a plain Q — an inconsistency the specification has and
/// every description written against it depends on.
public struct Biquad {
  public enum Response: Sendable {
    case lowpass, highpass, bandpass
  }

  public let response: Response
  public let sampleRate: Double

  var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
  var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

  @_noAllocation
  public init(response: Response, sampleRate: Double) {
    self.response = response
    self.sampleRate = sampleRate
  }

  /// Cheap enough to call per sample, which a swept filter does.
  @_noAllocation
  public mutating func set(frequency: Double, q: Double) {
    let nyquist = sampleRate * 0.5
    let normalised = max(0, min(1, frequency / nyquist))
    let w0 = Double.pi * normalised
    let cosine = dbCos(w0)
    let sine = dbSin(w0)

    let alpha: Double
    switch response {
    case .lowpass, .highpass: alpha = sine / (2 * dbPow(10, q / 20))
    case .bandpass: alpha = q > 0 ? sine / (2 * q) : 0
    }

    let a0 = 1 + alpha
    switch response {
    case .lowpass:
      b0 = (1 - cosine) / 2 / a0
      b1 = (1 - cosine) / a0
      b2 = b0
    case .highpass:
      b0 = (1 + cosine) / 2 / a0
      b1 = -(1 + cosine) / a0
      b2 = b0
    case .bandpass:
      b0 = alpha / a0
      b1 = 0
      b2 = -alpha / a0
    }
    a1 = -2 * cosine / a0
    a2 = (1 - alpha) / a0
  }

  @_noAllocation
  public mutating func process(_ input: Double) -> Double {
    let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2 = x1
    x1 = input
    y2 = y1
    y1 = output
    return output
  }
}
