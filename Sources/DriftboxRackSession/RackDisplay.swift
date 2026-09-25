import Foundation

#if canImport(CoreGraphics)
  // `CGRect(x:y:width:height:)` and the rest are CoreGraphics' own on Apple's platforms, where
  // Foundation alone gives the types without them.
  import CoreGraphics
#endif

/// What the hand-built faceplates make of a reading: the reference's `tuner-display.ts`,
/// `meter-display.ts` and `looper-display.ts`, which are pure and so are these.
public enum RackDisplay {
  public struct Tuning: Equatable, Sendable {
    public var detected: Bool
    public var note: String
    public var octave: Int?
    public var cents: Double
    public var frequency: Double

    public init(detected: Bool, note: String, octave: Int?, cents: Double, frequency: Double) {
      self.detected = detected
      self.note = note
      self.octave = octave
      self.cents = cents
      self.frequency = frequency
    }
  }

  public static let notes = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

  /// The equal-tempered note a frequency is nearest, against `reference` for A4, and how far off
  /// it is in cents; nothing when the detector is not sure enough to say.
  public static func tuning(frequency: Double, reference: Double, clarity: Double) -> Tuning {
    guard frequency > 0, reference > 0, clarity >= 0.55 else {
      return Tuning(detected: false, note: "—", octave: nil, cents: 0, frequency: 0)
    }
    let midi = 69 + 12 * log2(frequency / reference)
    let nearest = Int(jsRound(midi))
    return Tuning(
      detected: true, note: notes[((nearest % 12) + 12) % 12],
      octave: Int((Double(nearest) / 12).rounded(.down)) - 1,
      cents: max(-50, min(50, (midi - Double(nearest)) * 100)), frequency: frequency)
  }

  /// −48dB to +3dB mapped onto a display's useful 0...1.
  public static func meterPosition(_ amplitude: Double) -> Double {
    guard amplitude > 0 else { return 0 }
    return max(0, min(1, (20 * log10(amplitude) + 48) / 51))
  }

  public static func meterLabel(_ amplitude: Double) -> String {
    guard amplitude > 0 else { return "−∞ dB" }
    let db = 20 * log10(amplitude)
    return (db >= 0 ? "+" : "") + fixed(db, 1) + " dB"
  }

  /// `1:05.3`, or `EMPTY`.
  public static func loopTime(_ seconds: Double) -> String {
    guard seconds > 0 else { return "EMPTY" }
    let minutes = Int((seconds / 60).rounded(.down))
    let rest = fixed(seconds - Double(minutes) * 60, 1)
    return "\(minutes):" + String(repeating: "0", count: max(0, 4 - rest.count)) + rest
  }

  /// Where each point of a waveform is drawn in a `width` by `height` box: evenly across, and
  /// up to 42% of the height either side of the middle.
  public static func waveformPoints(_ waveform: [Float], width: Double, height: Double) -> [CGPoint] {
    guard !waveform.isEmpty else {
      return [CGPoint(x: 0, y: height / 2), CGPoint(x: width, y: height / 2)]
    }
    let last = Double(max(1, waveform.count - 1))
    return waveform.enumerated().map { index, value in
      CGPoint(
        x: Double(index) / last * width, y: height / 2 - max(-1, min(1, Double(value))) * (height * 0.42))
    }
  }

  /// JavaScript's `toFixed`: a half goes up, where `%f` would take it to the even digit — so
  /// 1.25 is "1.3" here as there.
  public static func fixed(_ value: Double, _ digits: Int) -> String {
    let scale = pow(10, Double(digits))
    let rounded = jsRound(value * scale)
    guard rounded.isFinite, abs(rounded) < 1e18 else { return "\(rounded / scale)" }
    // Written out from the whole number of the last digit's units, rather than by `%f`, which is
    // the old Foundation's on Android.
    let units = Int(rounded)
    let magnitude = String(units.magnitude)
    let padded = String(repeating: "0", count: max(0, digits + 1 - magnitude.count)) + magnitude
    let whole = padded.dropLast(digits)
    let sign = units < 0 ? "-" : ""
    return digits > 0 ? "\(sign)\(whole).\(padded.suffix(digits))" : "\(sign)\(whole)"
  }

  /// JavaScript's `Math.round`: halves go up, not away from zero.
  public static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }
}
