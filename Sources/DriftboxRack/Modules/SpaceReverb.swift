import DriftboxDSP

/// Reverb, as a feedback delay network: eight coprime lines through a Householder matrix, damped
/// in the loop, under four algorithms — Room, Hall and Plate (both with input diffusion) and
/// Spring (dispersion inside the loop) — with a one-pole EQ and an input-keyed gate on the wet.
/// A port of `reverb.ts`; named for the module so it does not shadow the engine's `Reverb`.
public struct ReverbModule {
  static let lineCount = 8
  static let algorithms = 4
  static let stages = 4

  let sampleRate: Double
  /// `[algorithm * 8 + line]`: each line's delay, per algorithm.
  let lengths: UnsafeMutablePointer<Int>
  /// Each line's buffer, Float32 as the reference's are, at the longest any algorithm asks for.
  let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  let lineLengths: UnsafeMutablePointer<Int>
  let write: UnsafeMutablePointer<Int>
  /// Plain number arrays in the reference, so doubles.
  let damped: UnsafeMutablePointer<Double>
  let taps: UnsafeMutablePointer<Double>

  /// Four Schroeder allpasses for input diffusion, Float32.
  let diffusion: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  let diffusionLengths: UnsafeMutablePointer<Int>
  let diffusionAt: UnsafeMutablePointer<Int>

  /// Four one-pole allpass states per line, Float32 as the reference's `Float32Array` is.
  let dispersion: UnsafeMutablePointer<Float>

  var lastDamp = Double.nan
  var dampCoefficient = 0.0

  var lowLeft = 0.0
  var lowRight = 0.0
  var highLeft = 0.0
  var highRight = 0.0
  var lastLowCut = Double.nan
  var lowCoefficient = 0.0
  var lastHighCut = Double.nan
  var highCoefficient = 1.0

  var envelope = 0.0
  var gain = 1.0
  var held = 0.0
  var lastRelease = Double.nan
  var releaseCoefficient = 1.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    let sets: [[Int]] = [
      [1327, 1543, 1873, 2053, 2399, 2687, 2927, 3271],
      [2647, 3011, 3457, 3833, 4297, 4721, 5153, 5647],
      [443, 587, 691, 811, 941, 1087, 1213, 1409],
      [887, 1063, 1229, 1381, 1523, 1699, 1871, 2003],
    ]
    // Scaled from the 44.1kHz these were chosen at, then nudged back to odd.
    func scale(_ samples: Int) -> Int {
      let rounded = jsRound((Double(samples) * sampleRate) / 44100)
      let scaled = rounded > 1 ? Int(rounded) : 1
      return scaled % 2 == 0 ? scaled + 1 : scaled
    }
    let count = Self.lineCount
    lengths = .allocate(capacity: Self.algorithms * count)
    for algorithm in 0..<Self.algorithms {
      for line in 0..<count {
        (lengths + algorithm * count + line).initialize(to: scale(sets[algorithm][line]))
      }
    }

    lines = .allocate(capacity: count)
    lineLengths = .allocate(capacity: count)
    for line in 0..<count {
      var most = 1
      for algorithm in 0..<Self.algorithms { most = max(most, lengths[algorithm * count + line]) }
      let buffer = UnsafeMutablePointer<Float>.allocate(capacity: most)
      buffer.initialize(repeating: 0, count: most)
      (lines + line).initialize(to: buffer)
      (lineLengths + line).initialize(to: most)
    }
    write = .allocate(capacity: count)
    write.initialize(repeating: 0, count: count)
    damped = .allocate(capacity: count)
    damped.initialize(repeating: 0, count: count)
    taps = .allocate(capacity: count)
    taps.initialize(repeating: 0, count: count)

    let diffusionSamples = [149, 211, 263, 331]
    diffusion = .allocate(capacity: Self.stages)
    diffusionLengths = .allocate(capacity: Self.stages)
    for stage in 0..<Self.stages {
      let length = scale(diffusionSamples[stage])
      let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
      buffer.initialize(repeating: 0, count: length)
      (diffusion + stage).initialize(to: buffer)
      (diffusionLengths + stage).initialize(to: length)
    }
    diffusionAt = .allocate(capacity: Self.stages)
    diffusionAt.initialize(repeating: 0, count: Self.stages)

    dispersion = .allocate(capacity: count * Self.stages)
    dispersion.initialize(repeating: 0, count: count * Self.stages)
  }

  func release() {
    for line in 0..<Self.lineCount { lines[line].deallocate() }
    for stage in 0..<Self.stages { diffusion[stage].deallocate() }
    lengths.deallocate()
    lines.deallocate()
    lineLengths.deallocate()
    write.deallocate()
    damped.deallocate()
    taps.deallocate()
    diffusion.deallocate()
    diffusionLengths.deallocate()
    diffusionAt.deallocate()
    dispersion.deallocate()
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let outLeft = outlets[0]
    let outRight = outlets[1]

    let sizeParam = params[0]
    let decayParam = params[1]
    let dampParam = params[2]
    let mixParam = params[3]
    let algorithmParam = params[4]
    let lowCutParam = params[5]
    let highCutParam = params[6]
    let gateParam = params[7]
    let threshParam = params[8]
    let holdParam = params[9]
    let releaseParam = params[10]

    let count = Self.lineCount

    for i in 0..<frames {
      let damp = Double(dampParam[i])
      if damp != lastDamp {
        lastDamp = damp
        dampCoefficient = damp < 0 ? 0 : damp > 0.99 ? 0.99 : damp
      }

      var algorithm = truncated(algorithmParam[i])
      if algorithm < 0 { algorithm = 0 } else if algorithm > 3 { algorithm = 3 }
      let lengths = self.lengths + algorithm * count
      let diffuse = algorithm == 1 ? 0.7 : algorithm == 2 ? 0.75 : 0
      let disperse = algorithm == 3 ? 0.6 : 0

      var size = Double(sizeParam[i])
      if size < 0.1 { size = 0.1 } else if size > 1 { size = 1 }

      var sum = 0.0
      for line in 0..<count {
        let buffer = lines[line]
        // `Math.max(1, Math.round(length * size))`, NaN and all.
        let rounded = jsRound(Double(lengths[line]) * size)
        let tap: Double
        if rounded.isNaN {
          // The reference reads `buffer[NaN]`, which is `undefined`, and carries NaN on.
          tap = .nan
        } else {
          var at = write[line] - (rounded > 1 ? Int(rounded) : 1)
          if at < 0 { at += lineLengths[line] }
          tap = Double(buffer[at])
        }
        taps[line] = tap
        sum += tap
      }

      var decay = Double(decayParam[i])
      if decay < 0 { decay = 0 } else if decay > 0.98 { decay = 0.98 }

      let share = (2 * sum) / Double(count)
      let raw = Double(input[i])

      var driven = raw
      if diffuse > 0 {
        for stage in 0..<Self.stages {
          let buffer = diffusion[stage]
          let at = diffusionAt[stage]
          let stored = Double(buffer[at])
          let held = driven + diffuse * stored
          driven = stored - diffuse * held
          buffer[at] = Float(held)
          diffusionAt[stage] = at + 1 >= diffusionLengths[stage] ? 0 : at + 1
        }
      }

      var wet = 0.0
      var wetRight = 0.0
      for line in 0..<count {
        let mixed = taps[line] - share
        damped[line] = mixed + (damped[line] - mixed) * dampCoefficient

        var fed = damped[line]
        if disperse > 0 {
          let base = line * 4
          for stage in 0..<Self.stages {
            let state = Double(dispersion[base + stage])
            let out = state - disperse * fed
            dispersion[base + stage] = Float(fed + disperse * out)
            fed = out
          }
        }

        let buffer = lines[line]
        buffer[write[line]] = Float(driven + fed * decay)
        write[line] += 1
        if write[line] >= lineLengths[line] { write[line] = 0 }
        wet += taps[line]
        wetRight += line % 2 == 0 ? taps[line] : -taps[line]
      }

      wet /= Double(count)
      wetRight /= Double(count)

      let lowCut = Double(lowCutParam[i])
      if lowCut > 20 {
        if lowCut != lastLowCut {
          lastLowCut = lowCut
          lowCoefficient = 1 - expDSP((-2 * Double.pi * lowCut) / sampleRate)
        }
        lowLeft += (wet - lowLeft) * lowCoefficient
        wet -= lowLeft
        lowRight += (wetRight - lowRight) * lowCoefficient
        wetRight -= lowRight
      }
      let highCut = Double(highCutParam[i])
      if highCut < 18000 {
        if highCut != lastHighCut {
          lastHighCut = highCut
          highCoefficient = 1 - expDSP((-2 * Double.pi * highCut) / sampleRate)
        }
        highLeft += (wet - highLeft) * highCoefficient
        wet = highLeft
        highRight += (wetRight - highRight) * highCoefficient
        wetRight = highRight
      }

      if gateParam[i] >= 0.5 {
        let magnitude = raw < 0 ? -raw : raw
        if magnitude > envelope {
          envelope = magnitude
        } else {
          envelope += (magnitude - envelope) * (1 - expDSP(-50 / sampleRate))
        }

        if envelope >= Double(threshParam[i]) {
          var hold = Double(holdParam[i])
          if !(hold > 0) { hold = 0 }
          held = hold * sampleRate
          gain = 1
        } else if held > 0 {
          held -= 1
          gain = 1
        } else {
          let release = Double(releaseParam[i])
          if release != lastRelease {
            lastRelease = release
            releaseCoefficient = release > 0 ? 1 - expDSP(-4.605170185988091 / (release * sampleRate)) : 1
          }
          gain += (0 - gain) * releaseCoefficient
        }
        wet *= gain
        wetRight *= gain
      } else {
        gain = 1
      }

      var mix = Double(mixParam[i])
      if mix < 0 { mix = 0 } else if mix > 1 { mix = 1 }
      let dry = raw * (1 - mix)
      outLeft[i] = Float(dry + wet * mix)
      outRight[i] = Float(dry + wetRight * mix)
    }
  }
}
