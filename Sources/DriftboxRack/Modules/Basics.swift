import DriftboxDSP

// The first dozen modules, each a line-for-line port of its file in
// `driftbox/packages/rack/src/modules`. Arithmetic is in doubles and stored as float32, which is
// what JavaScript does with a Float32Array: reading a float widens it exactly, and every
// intermediate is a double until it is written back.

/// The end of a chain: a level, and its outlet carries the signal on so it can be patched onward.
/// Pan, mute and solo are the graph's, which is the only place that sees every Out at once.
enum Out {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let left = inlets[0]
    let right = inlets[1]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let level = params[0]
    for i in 0..<frames {
      let gain = Double(level[i])
      outLeft[i] = Float(Double(left[i]) * gain)
      outRight[i] = Float(Double(right[i]) * gain)
    }
  }
}

/// Band-limited saw, pulse and triangle from C2, a volt an octave.
public struct VCO {
  let sampleRate: Double
  var osc = Osc()
  var lastExponent = Double.nan
  var lastRatio = 1.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let pitch = inlets[0]
    let fm = inlets[1]
    let out = outlets[0]
    let tune = params[0]
    let shape = params[1]
    let width = params[2]
    for i in 0..<frames {
      let exponent = Double(tune[i]) / 12 + Double(pitch[i])
      if exponent != lastExponent {
        lastExponent = exponent
        lastRatio = exp2(exponent)
      }
      let carrier = 65.40639132514966 * lastRatio
      var frequency = carrier + carrier * Double(fm[i])
      if !(frequency > 0) { frequency = 0 }
      var dt = frequency / sampleRate
      if dt > 0.45 { dt = 0.45 }
      out[i] = Float(osc.next(dt, shape: truncated(shape[i]), width: Double(width[i])))
    }
  }
}

/// White and pink at once: Paul Kellet's filter over the white.
public struct NoiseSource {
  var random: RackRandom
  var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let white = outlets[0]
    let pink = outlets[1]
    for i in 0..<frames {
      let w = random.next()
      white[i] = Float(w)
      b0 = 0.99886 * b0 + w * 0.0555179
      b1 = 0.99332 * b1 + w * 0.0750759
      b2 = 0.969 * b2 + w * 0.153852
      b3 = 0.8665 * b3 + w * 0.3104856
      b4 = 0.55 * b4 + w * 0.5329522
      b5 = -0.7616 * b5 - w * 0.016898
      pink[i] = Float((b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.325)
      b6 = w * 0.115926
    }
  }
}

/// Volume from a cable, linear or squared.
enum VCA {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let cv = inlets[1]
    let out = outlets[0]
    let gain = params[0]
    let curve = params[1]
    let squared = truncated(curve[0]) == 1
    for i in 0..<frames {
      var level = Double(gain[i]) + Double(cv[i])
      if level < 0 { level = 0 } else if level > 1 { level = 1 }
      out[i] = squared ? Float(Double(input[i]) * level * level) : Float(Double(input[i]) * level)
    }
  }
}

/// Four in, one out, a level and a CV on each.
enum Mixer {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let out = outlets[0]
    for i in 0..<frames {
      var sum = 0.0
      for channel in 0..<4 {
        var level = Double(params[channel][i]) + Double(inlets[channel + 4][i])
        if level < -2 { level = -2 } else if level > 2 { level = 2 }
        sum += Double(inlets[channel][i]) * level
      }
      out[i] = Float(sum)
    }
  }
}

/// The 303's filter, the engine's own ladder, with its cutoff in octaves from a cable.
public struct LadderModule {
  var filter: Ladder

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let cutoffCv = inlets[1]
    let resonanceCv = inlets[2]
    let out = outlets[0]
    let cutoff = params[0]
    let resonance = params[1]
    for i in 0..<frames {
      var frequency = Double(cutoff[i])
      let octaves = Double(cutoffCv[i])
      if octaves != 0 { frequency *= exp2(octaves) }
      var q = Double(resonance[i]) + Double(resonanceCv[i])
      if q < 0 { q = 0 } else if q > 1 { q = 1 }
      out[i] = Float(filter.process(Double(input[i]), cutoff: frequency, resonance: q))
    }
  }
}

/// A trapezoidal state-variable filter (Simper's), with all four responses on their own outlets.
public struct SVF {
  let sampleRate: Double
  var ic1 = 0.0, ic2 = 0.0
  var lastFrequency = Double.nan, lastDamping = Double.nan
  var a1 = 0.0, a2 = 0.0, a3 = 0.0, k = 0.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let cutoffCv = inlets[1]
    let resonanceCv = inlets[2]
    let low = outlets[0]
    let high = outlets[1]
    let band = outlets[2]
    let notch = outlets[3]
    let cutoff = params[0]
    let resonance = params[1]
    let ceiling = sampleRate * 0.45
    for i in 0..<frames {
      var frequency = Double(cutoff[i])
      let octaves = Double(cutoffCv[i])
      if octaves != 0 { frequency *= exp2(octaves) }
      if frequency < 20 { frequency = 20 } else if frequency > ceiling { frequency = ceiling }
      var res = Double(resonance[i]) + Double(resonanceCv[i])
      if res < 0 { res = 0 } else if res > 1 { res = 1 }
      let damping = 2 - 1.96 * res
      if frequency != lastFrequency || damping != lastDamping {
        lastFrequency = frequency
        lastDamping = damping
        let g = tanDSP((Double.pi * frequency) / sampleRate)
        k = damping
        a1 = 1 / (1 + g * (g + damping))
        a2 = g * a1
        a3 = g * a2
      }
      let v0 = Double(input[i])
      let v3 = v0 - ic2
      let v1 = a1 * ic1 + a2 * v3
      let v2 = ic2 + a2 * ic1 + a3 * v3
      ic1 = 2 * v1 - ic1
      ic2 = 2 * v2 - ic2
      let hp = v0 - k * v1 - v2
      low[i] = Float(v2)
      high[i] = Float(hp)
      band[i] = Float(v1)
      notch[i] = Float(v0 - k * v1)
    }
  }
}

/// Attack, decay, sustain, release, from a gate or a trigger.
public struct ADSR {
  let sampleRate: Double
  var stage = 0
  var value = 0.0
  var lastGate = 0, lastTrig = 0
  var lastAttack = Double.nan, attackStep = 1.0
  var lastDecay = Double.nan, decayCoef = 0.0
  var lastRelease = Double.nan, releaseCoef = 0.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let gateIn = inlets[0]
    let trigIn = inlets[1]
    let out = outlets[0]
    let attack = params[0]
    let decay = params[1]
    let sustain = params[2]
    let release = params[3]
    for i in 0..<frames {
      let gate = gateIn[i] >= 0.5 ? 1 : 0
      let trig = trigIn[i] >= 0.5 ? 1 : 0
      if (gate == 1 && lastGate == 0) || (trig == 1 && lastTrig == 0) {
        stage = 1
      } else if gate == 0 && lastGate == 1 {
        stage = 4
      }
      lastGate = gate
      lastTrig = trig
      if stage == 1 {
        let a = Double(attack[i])
        if a != lastAttack {
          lastAttack = a
          attackStep = 1 / max(1, a * sampleRate)
        }
        value += attackStep
        if value >= 1 {
          value = 1
          stage = 2
        }
      } else if stage == 2 {
        let d = Double(decay[i])
        if d != lastDecay {
          lastDecay = d
          decayCoef = powDSP(0.01, 1 / max(1, d * sampleRate))
        }
        let target = Double(sustain[i])
        value = target + (value - target) * decayCoef
        if abs(value - target) < 1e-5 {
          value = target
          stage = 3
        }
      } else if stage == 3 {
        value = Double(sustain[i])
      } else if stage == 4 {
        let r = Double(release[i])
        if r != lastRelease {
          lastRelease = r
          releaseCoef = powDSP(0.01, 1 / max(1, r * sampleRate))
        }
        value *= releaseCoef
        if value < 1e-5 {
          value = 0
          stage = 0
        }
      } else {
        value = 0
      }
      out[i] = Float(value)
    }
  }
}

/// A slow oscillator, bipolar and unipolar at once, with a random step shape.
public struct LFO {
  let sampleRate: Double
  var random: RackRandom
  var phase = 0.0
  var lastReset = 0
  var held: Double

  init(sampleRate: Double, id: String) {
    self.sampleRate = sampleRate
    random = RackRandom(seed: id)
    held = random.next()
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let rateCv = inlets[0]
    let reset = inlets[1]
    let bi = outlets[0]
    let uni = outlets[1]
    let rate = params[0]
    let shape = params[1]
    for i in 0..<frames {
      let gate = reset[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastReset == 0 {
        phase = 0
        held = random.next()
      }
      lastReset = gate
      var frequency = Double(rate[i])
      let octaves = Double(rateCv[i])
      if octaves != 0 { frequency *= exp2(octaves) }
      if frequency < 0 { frequency = 0 } else if frequency > 40 { frequency = 40 }
      phase += frequency / sampleRate
      if phase >= 1 {
        phase -= 1
        if phase >= 1 { phase = 0 }
        held = random.next()
      }
      let t = phase
      let value: Double
      switch truncated(shape[i]) {
      case 1: value = t < 0.5 ? 4 * t - 1 : 3 - 4 * t
      case 2: value = 2 * t - 1
      case 3: value = t < 0.5 ? 1 : -1
      case 4: value = held
      default: value = sin2pi(t)
      }
      bi[i] = Float(value)
      uni[i] = Float(value * 0.5 + 0.5)
    }
  }
}

/// Scale, invert and shift.
enum Offset {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let out = outlets[0]
    let gain = params[0]
    let offset = params[1]
    for i in 0..<frames {
      out[i] = Float(Double(input[i]) * Double(gain[i]) + Double(offset[i]))
    }
  }
}

/// Grab the input on a trigger's rising edge, and hold it.
public struct SampleHold {
  var held = 0.0
  var lastTrig = 0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let trig = inlets[1]
    let out = outlets[0]
    for i in 0..<frames {
      let gate = trig[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastTrig == 0 { held = Double(input[i]) }
      lastTrig = gate
      out[i] = Float(held)
    }
  }
}

/// Two seconds of echo, wet only, with its time in octaves from a cable.
public struct Delay {
  let sampleRate: Double
  /// Float32, as the reference's buffer is: what goes round the feedback loop is rounded to it.
  let buffer: UnsafeMutablePointer<Float>
  let length: Int
  var write = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    length = Int((sampleRate * 2).rounded(.up)) + 4
    buffer = .allocate(capacity: length)
    buffer.initialize(repeating: 0, count: length)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ frames: Int) {
    let input = inlets[0]
    let timeCv = inlets[1]
    let feedbackCv = inlets[2]
    let out = outlets[0]
    let time = params[0]
    let feedback = params[1]
    let longest = Double(length - 3)
    for i in 0..<frames {
      var seconds = Double(time[i])
      let octaves = Double(timeCv[i])
      if octaves != 0 { seconds /= exp2(octaves) }
      var samples = seconds * sampleRate
      if samples < 1 { samples = 1 } else if samples > longest { samples = longest }
      var read = Double(write) - samples
      if read < 0 { read += Double(length) }
      // Never negative, so truncating is the reference's `Math.floor`.
      let index = Int(read)
      let fraction = read - Double(index)
      let a = Double(buffer[index])
      let b = Double(buffer[index + 1 < length ? index + 1 : 0])
      let delayed = a + (b - a) * fraction
      out[i] = Float(delayed)
      var fb = Double(feedback[i]) + Double(feedbackCv[i])
      if fb < 0 { fb = 0 } else if fb > 0.98 { fb = 0.98 }
      var written = Double(input[i]) + delayed * fb
      if !(written > -8 && written < 8) { written = written > 0 ? 8 : written < 0 ? -8 : 0 }
      buffer[write] = Float(written)
      write += 1
      if write >= length { write = 0 }
    }
  }
}
