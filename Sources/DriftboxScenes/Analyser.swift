import DriftboxDSP
import Foundation

/// The web's `AnalyserNode` on the mix, as the scenes read it: 2048 frames under a Blackman
/// window, magnitudes smoothed over time, in decibels between -100 and -30 as bytes. Then the
/// web's `readBands`: the spectrum in bands of a constant ratio, since the ear is logarithmic
/// and a drum machine's spectrum is mostly hats otherwise. Two scenes that split "bass" at
/// different places would look like one of them was broken, so every scene reads through this.
public final class Analyser {
  public static let size = 2048
  public static let bins = size / 2

  /// Web Audio's `smoothingTimeConstant`; the web engine sets 0.75.
  public var smoothing: Double = 0.75
  public var minDecibels: Double = -100
  public var maxDecibels: Double = -30

  /// The spectrum as `getByteFrequencyData` gives it, after the last `update`.
  public private(set) var bytes = [UInt8](repeating: 0, count: bins)

  private var window: [Double]
  private var real = [Double](repeating: 0, count: size)
  private var imaginary = [Double](repeating: 0, count: size)
  private var smoothed = [Double](repeating: 0, count: bins)

  public init() {
    // Blackman, as the specification has it.
    let alpha = 0.16
    let a0 = (1 - alpha) / 2
    let a1 = 0.5
    let a2 = alpha / 2
    window = (0..<Self.size).map { n in
      let x = 2 * Double.pi * Double(n) / Double(Self.size)
      return a0 - a1 * cos(x) + a2 * cos(2 * x)
    }
  }

  /// Analyse the most recent `size` frames, oldest first.
  public func update(_ samples: UnsafeBufferPointer<Float>) {
    precondition(samples.count == Self.size)
    for n in 0..<Self.size {
      real[n] = Double(samples[n]) * window[n]
      imaginary[n] = 0
    }
    FFT.forward(real: &real, imaginary: &imaginary)
    let scale = 1 / Double(Self.size)
    let range = 255 / (maxDecibels - minDecibels)
    for k in 0..<Self.bins {
      let magnitude = (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot() * scale
      smoothed[k] = smoothing * smoothed[k] + (1 - smoothing) * magnitude
      let decibels = smoothed[k] > 0 ? 20 * log10(smoothed[k]) : -Double.infinity
      let scaled = range * (decibels - minDecibels)
      bytes[k] = UInt8(max(0, min(255, scaled.isNaN ? 0 : scaled.rounded(.down))))
    }
  }

  /// The spectrum in `count` bands, each covering a constant ratio of it, 0...1.
  public func bands(_ count: Int) -> [Float] {
    let bins = Double(Self.bins)
    return (0..<count).map { band in
      let from = Int(pow(bins, Double(band) / Double(count)).rounded(.down))
      let to = max(from + 1, Int(pow(bins, Double(band + 1) / Double(count)).rounded(.down)))
      var sum = 0
      for k in from..<min(to, Self.bins) { sum += Int(bytes[k]) }
      return Float(sum) / Float((to - from) * 255)
    }
  }

  /// The web's `readLevels`: roughly, the first few bins are the kick's fundamental and the
  /// top half is hats and the noise in snares and claps.
  public func wideLevels() -> (bass: Float, high: Float) {
    let lowEnd = max(1, Int(Double(Self.bins) * 0.035))
    var bass = 0
    for k in 0..<lowEnd { bass += Int(bytes[k]) }
    let highStart = Int(Double(Self.bins) * 0.55)
    var high = 0
    for k in highStart..<Self.bins { high += Int(bytes[k]) }
    return (Float(bass) / Float(lowEnd * 255), Float(high) / Float((Self.bins - highStart) * 255))
  }

  /// Bass, mid and high as the surface scenes take them: eight bands, three, three and two.
  public func levels() -> (bass: Float, mid: Float, high: Float) {
    let b = bands(8)
    return ((b[0] + b[1] + b[2]) / 3, (b[3] + b[4] + b[5]) / 3, (b[6] + b[7]) / 2)
  }

  /// Asymmetric smoothing: snap up on a transient, ease down afterwards — the difference
  /// between a visualiser that is reading the music and one that is merely moving.
  public static func ease(_ current: Float, toward target: Float, dt: Float, fall: Float = 3.2) -> Float {
    target > current ? target : current + (target - current) * min(1, dt * fall)
  }
}
