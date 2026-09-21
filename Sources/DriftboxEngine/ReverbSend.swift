import DriftboxDSP
import DriftboxSeq

/// The reverb send: a convolver fed a generated room. A port of the reverb half of `Sends` in
/// `driftbox/packages/engine/src/effects.ts`.
public enum ReverbSend {
  /// Two fixed seeds, one per side. Independent noise per channel is what makes the room wide;
  /// fixed is what makes a render the same room twice.
  static let seeds: [UInt32] = [0x726f_6f6d, 0x7769_6465]

  /// A generated impulse response: noise under a decaying envelope, with the high end rolled off
  /// progressively along the tail. That last part is what makes it a room rather than noise
  /// fading out — in anything physical the high frequencies are absorbed first, so a tail that
  /// darkens as it decays reads as a space.
  public static func impulseResponse(seconds: Double, damping: Double, sampleRate: Double) -> [[Float]] {
    let length = max(1, Int((sampleRate * seconds).rounded(.up)))
    return seeds.map { seed in
      var random = SeededRandom(seed: seed)
      var filtered = 0.0
      return (0..<length).map { index in
        let t = Double(index) / Double(length)
        // A one-pole low-pass whose corner closes as the tail decays.
        let coefficient = max(0.015, (1 - damping) * (1 - t) + 0.015)
        filtered += coefficient * (random.next() * 2 - 1 - filtered)
        // The power is what makes the tail taper rather than stop.
        return Float(filtered * power(1 - t, 2.2))
      }
    }
  }

  /// The room a song's settings ask for.
  public static func impulseResponse(for fx: FxParams, sampleRate: Double) -> [[Float]] {
    impulseResponse(seconds: 0.3 + fx.reverbSize * 3.5, damping: fx.reverbDamping, sampleRate: sampleRate)
  }

  /// What the browser's `ConvolverNode` multiplies an impulse response by when `normalize` is on,
  /// which it is unless turned off: the response's RMS level, calibrated so that a reverb sits at
  /// about the level of the dry signal whatever room it is given.
  public static func normalisation(_ response: [[Float]], sampleRate: Double) -> Double {
    let length = response.first?.count ?? 0
    guard length > 0 else { return 1 }
    var power = 0.0
    for channel in response { for sample in channel { power += Double(sample) * Double(sample) } }
    power = (power / Double(response.count * length)).squareRoot()
    if !power.isFinite || power < 0.000125 { power = 0.000125 }
    var scale = 1 / power
    scale *= power10(-58 * 0.05)
    scale *= 44100 / sampleRate
    if response.count == 4 { scale *= 0.5 }
    return scale
  }

  /// A mono signal through the room: one side of the response for each side out.
  public static func render(_ input: [Float], fx: FxParams, sampleRate: Double, frames: Int)
    -> VoiceRenderer.Stereo
  {
    let response = impulseResponse(for: fx, sampleRate: sampleRate)
    let scale = Float(normalisation(response, sampleRate: sampleRate))
    let sides = response.map { side in
      var wet = Convolution.convolve(input, with: side).prefix(frames).map { $0 * scale }
      wet += [Float](repeating: 0, count: max(0, frames - wet.count))
      return wet
    }
    return VoiceRenderer.Stereo(left: sides[0], right: sides[1])
  }
}

private func power(_ base: Double, _ exponent: Double) -> Double { powDSP(base, exponent) }
private func power10(_ exponent: Double) -> Double { powDSP(10, exponent) }
