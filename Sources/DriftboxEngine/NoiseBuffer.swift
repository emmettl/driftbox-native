import DriftboxDSP

/// The engine's noise, generated once and read by every hit. A port of `noiseBuffer` and
/// `noiseOffsetSeed` in `driftbox/packages/engine/src/render.ts`.
///
/// Stored as 32-bit floats because the reference's is — an `AudioBuffer` — and the rounding is
/// part of the waveform.
struct NoiseBuffer {
  let sampleRate: Double
  let samples: [Float]

  /// The seed ordinary noise gets when a voice does not name one. Fixed, so that two renders of
  /// one song are the same song.
  static let defaultSeed: UInt32 = 0x6472_6966

  init(contextSampleRate: Double, noise: Noise) {
    sampleRate = noise.sampleRate ?? contextSampleRate
    // Four seconds covers the longest cymbal without looping its generated ROM; ordinary noise
    // keeps two and loops invisibly. Keyed on whether a seed was asked for, not on the seed used.
    let seconds = noise.seed == nil ? 2.0 : 4.0
    let length = Int((sampleRate * seconds).rounded(.down))
    var random = SeededRandom(
      seed: noise.seed.map { UInt32(truncatingIfNeeded: Int64($0)) } ?? Self.defaultSeed)
    let maximumCode = noise.bitDepth.map { pow2(max(2, min(16, $0))) - 1 } ?? 0

    var samples = [Float](repeating: 0, count: length)
    for index in 0..<length {
      let value = random.next() * 2 - 1
      samples[index] = Float(
        maximumCode > 0 ? (jsRound(((value + 1) * maximumCode) / 2) / maximumCode) * 2 - 1 : value)
    }
    self.samples = samples
  }

  /// Which slice of the buffer a hit reads from, in seconds.
  ///
  /// A function of the hit rather than of chance. It exists so two overlapping noise sources do
  /// not read the same samples and comb-filter each other — most audibly inside a clap, which is
  /// one voice retriggering itself. That needs offsets to differ from each other; it never needed
  /// them to differ from one render to the next. A seeded source is a ROM and starts at zero.
  static func offset(voice: String, sourceIndex: Int, start: Double, seeded: Bool) -> Double {
    if seeded { return 0 }
    var hash: UInt32 = 0x811c_9dc5
    func mix(_ value: UInt32) {
      hash ^= value
      hash = hash &* 0x0100_0193
    }
    for unit in voice.utf16 { mix(UInt32(unit)) }
    mix(UInt32(truncatingIfNeeded: sourceIndex + 1))
    // Milliseconds, so a time that differs in its last bit cannot land on a different slice.
    mix(UInt32(truncatingIfNeeded: Int64(jsRound(start * 1000))))
    // A final avalanche: FNV leaves adjacent inputs with close seeds, and xorshift32's first
    // output from two close seeds is close too.
    hash ^= hash >> 15
    hash = hash &* 0x2c1b_3c6d
    hash ^= hash >> 12

    var pick = SeededRandom(seed: hash == 0 ? 1 : hash)
    _ = pick.next()
    return pick.next() * 1.5
  }
}

/// `Math.round`: halves towards positive infinity.
@_noAllocation
func jsRound(_ value: Double) -> Double {
  // `rounded(.down)` names an enum the checker will not allow; the integer conversion is the same
  // thing for the magnitudes here.
  var floor = Double(Int(value))
  if floor > value { floor -= 1 }
  return value - floor >= 0.5 ? floor + 1 : floor
}

/// 2 to a whole-number power, without reaching for `pow`.
private func pow2(_ exponent: Double) -> Double {
  var result = 1.0
  for _ in 0..<Int(exponent) { result *= 2 }
  return result
}
