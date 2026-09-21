/// Sixteenths.
public let stepsPerBeat = 4

public func secondsPerStep(bpm: Double) -> Double {
  60 / bpm / Double(stepsPerBeat)
}

/// How late a step lands, in seconds, because of swing. Swing delays the off-beat sixteenths and
/// leaves the on-beats alone. 0 is straight; about 0.67 puts the off-beat on a triplet.
public func swingDelay(step: Int, swing: Double, stepSeconds: Double) -> Double {
  guard wrap(step, 2) == 1 else { return 0 }
  return clamp(swing, 0, 1) * 0.5 * stepSeconds
}
