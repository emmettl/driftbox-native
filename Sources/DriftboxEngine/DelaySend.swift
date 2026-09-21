import DriftboxDSP
import DriftboxSeq

/// Delay lengths, in sixteenth-note steps. Snapped, not continuous: a delay that is not a
/// division of the bar smears the groove instead of reinforcing it. 3 — the dotted eighth — is the
/// default because its repeats land between the beats rather than on them.
public let delayDivisions = [2, 3, 4, 6, 8]

public func delayDivision(_ knob: Double) -> Int {
  delayDivisions[Int(jsRound(max(0, min(1, knob)) * Double(delayDivisions.count - 1)))]
}

/// The delay send: a tempo-synced delay with a low-pass **inside** its feedback loop, so each
/// repeat is darker than the one before it — which sounds like distance, where a filter after the
/// loop would sound like a tone control. A port of the delay half of `Sends` in
/// `driftbox/packages/engine/src/effects.ts`.
///
/// Every knob arrives as an exponential approach, never a jump: a delay line whose length jumps
/// re-reads its buffer from somewhere else and clicks, where one that glides pitch-bends its tail,
/// which is the sound a tape delay makes and nobody minds.
public struct DelaySend: ~Copyable {
  public let sampleRate: Double
  var line: DelayLine
  var damp: Biquad
  var time: TargetSmoother
  var feedback: TargetSmoother
  var tone: TargetSmoother
  /// What has come back round the loop and not yet been written in. The browser computes a loop
  /// a render quantum at a time, and the way it breaks the cycle hands the filter the delay's
  /// output from the quantum *before*: every trip round the loop is 128 frames longer than the
  /// delay time says. Measured: the second repeat lands 128 frames late, the third 256. So a
  /// dotted-eighth delay in the reference drifts 2.7ms further off the grid with each repeat, and
  /// always has — it is part of how the songs sound, and is kept.
  var returning = [Float](repeating: 0, count: TargetSmoother.quantum)

  public init(sampleRate: Double) {
    self.sampleRate = sampleRate
    line = DelayLine(maximumSeconds: 2, sampleRate: sampleRate)
    damp = Biquad(response: .lowpass, sampleRate: sampleRate)
    // Where the browser's nodes start before anything is asked of them: no delay, a loop gain of
    // one, and a filter at 350Hz. The approaches below begin from these, audibly or not.
    time = TargetSmoother(value: 0, sampleRate: sampleRate)
    feedback = TargetSmoother(value: 1, sampleRate: sampleRate)
    tone = TargetSmoother(value: 350, sampleRate: sampleRate)
    update(FxParams(), bpm: 120, atFrame: 0)
  }

  /// Apply the song's settings from `frame` on. Safe to call as often as a knob moves.
  public mutating func update(_ fx: FxParams, bpm: Double, atFrame frame: Int) {
    let seconds = secondsPerStep(bpm: bpm) * Double(delayDivision(fx.delayTime))
    time.setTarget(Float(min(2, seconds)), at: frame, timeConstant: 0.05)
    // Stops well short of one. At unity the loop never decays and the bus climbs until it clips;
    // 0.85 is what holds with every voice sending at full and the knob at maximum.
    feedback.setTarget(Float(min(0.85, fx.delayFeedback * 0.85)), at: frame, timeConstant: 0.02)
    tone.setTarget(Float(600 * pow16(fx.delayTone)), at: frame, timeConstant: 0.02)
  }

  /// One frame through the send. Call once per frame, in order.
  ///
  /// The delay's length is read every frame, so a tempo change bends the pitch of what is already
  /// in the line rather than stepping it.
  public mutating func process(_ input: Float, frame: Int) -> Float {
    let output = line.read(secondsAgo: time.next(frame: frame), inALoop: true)
    damp.set(frequency: Double(tone.next(frame: frame)), q: 1)
    let regenerated = Float(damp.process(Double(output))) * feedback.next(frame: frame)

    let slot = frame % TargetSmoother.quantum
    line.write(input + returning[slot])
    returning[slot] = regenerated
    return output
  }
}

/// 16 to a power, by way of 2 to four times it.
private func pow16(_ exponent: Double) -> Double {
  ratioRange(exponent, 1, 16)
}
