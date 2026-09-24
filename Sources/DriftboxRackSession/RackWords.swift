import DriftboxRack

/// How the rack writes its numbers, as the reference writes them: what a knob reads, a routing's
/// end, a trim pot. Words for a face to draw, whichever platform draws it.
extension RackDisplay {
  /// A value in words, guessed from its range as the reference guesses it: thousands are hertz,
  /// three orders of magnitude inside ten are seconds, a range across ±12 is signed semitones.
  public static func value(_ def: ParamDef, _ value: Double) -> String {
    if def.max > 1000 {
      return value >= 1000 ? fixed(value / 1000, 2) + "k" : "\(Int(jsRound(value)))"
    }
    if def.max <= 10, def.min >= 0.0001, def.max / max(def.min, 1e-6) > 100 {
      return value < 0.1 ? "\(Int(jsRound(value * 1000)))ms" : fixed(value, 2) + "s"
    }
    if def.min <= -12, def.max >= 12 {
      let whole = Int(value.rounded())
      return whole > 0 ? "+\(whole)" : "\(whole)"
    }
    return fixed(value, 2)
  }

  /// A routing's end: enough digits to be useful and few enough to fit, a cutoff in whole numbers
  /// and a resonance not, as the reference rounds it.
  public static func route(_ value: Double) -> String {
    let rounded = abs(value) >= 100 ? jsRound(value) : jsRound(value * 100) / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }

  /// A trim as the reference writes one: `0.55×`, `−0.30×`.
  public static func trim(_ value: Double) -> String {
    "\(value < 0 ? "−" : "")\(fixed(abs(value), 2))×"
  }

  /// A trim held to its range and to hundredths, as the reference's pot turns.
  public static func trimStep(_ value: Double) -> Double {
    jsRound(max(-1, min(1, value)) * 100) / 100
  }

  /// A trim pot's pointer, in radians from straight up: -135° at -1, straight up at 0, 135° at 1.
  public static func potAngle(_ value: Double) -> Double { (-135 + (value + 1) / 2 * 270) * .pi / 180 }
}
