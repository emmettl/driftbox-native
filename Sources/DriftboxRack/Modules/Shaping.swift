import DriftboxDSP

// Drive, distortion, cabinet, eq, imager, compressor, limiter: each a line-for-line port of its file
// in `driftbox/packages/rack/src/modules`. The family's processors are one enum here, behind one
// case of `RackProcessor`, so its modules can be added without touching anyone else's.
//
// As in `Basics.swift`, arithmetic is in doubles and every buffer write is rounded to float32,
// which is what JavaScript does with a Float32Array.

public enum ShapingProcessor {
  case drive(DriveModule)
  case distortion(DistortionModule)
  case cabinet(CabinetModule)
  case eq(EQModule)
  case imager(ImagerModule)
  case compressor(CompressorModule)
  case limiter(LimiterModule)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .drive(var module):
      module.process(inlets, outlets, params, context)
      self = .drive(module)
    case .distortion(var module):
      module.process(inlets, outlets, params, context)
      self = .distortion(module)
    case .cabinet(var module):
      module.process(inlets, outlets, params, context)
      self = .cabinet(module)
    case .eq(var module):
      module.process(inlets, outlets, params, context)
      self = .eq(module)
    case .imager(var module):
      module.process(inlets, outlets, params, context)
      self = .imager(module)
    case .compressor(var module):
      module.process(inlets, outlets, params, context)
      self = .compressor(module)
    case .limiter(var module):
      module.process(inlets, outlets, params, context)
      self = .limiter(module)
    }
  }

  func meter() -> MeterReading? { nil }

  mutating func release() {
    if case .limiter(let module) = self { module.release() }
  }
}

/// `Math.max(a, b)`, which answers NaN when either is, where Swift's `max` would not.
@_noAllocation
private func jsMax(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  return a > b ? a : b
}

/// A one-pole lowpass's exact discrete-time coefficient, `1 - exp(-2πf / sr)`, as every module
/// here writes it.
@_noAllocation
private func onePole(_ frequency: Double, _ sampleRate: Double) -> Double {
  1 - expDSP((-2 * Double.pi * frequency) / sampleRate)
}

// MARK: - Drive

/// Saturation: `tanh`, normalised so the knob changes the sound and not the level, then a 5Hz DC
/// blocker for the offset an asymmetric bias rectifies out of the signal.
public struct DriveModule {
  let pole: Double
  var lastDrive = Double.nan
  var scale = 1.0
  var lastIn = 0.0
  var lastOut = 0.0

  init(sampleRate: Double) {
    pole = expDSP((-2 * Double.pi * 5) / sampleRate)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let cv = inlets[1]
    let out = outlets[0]
    let drive = params[0]
    let bias = params[1]
    for i in 0..<frames {
      var amount = Double(drive[i]) + Double(cv[i]) * 20
      if amount < 0.1 { amount = 0.1 } else if amount > 40 { amount = 40 }
      if amount != lastDrive {
        lastDrive = amount
        scale = 1 / tanhDSP(amount)
      }
      let shaped = tanhDSP((Double(input[i]) + Double(bias[i])) * amount) * scale
      // One-pole DC blocker: a differentiator with a pole put back just under unity.
      let blocked = shaped - lastIn + pole * lastOut
      lastIn = shaped
      lastOut = blocked
      out[i] = Float(blocked)
    }
  }
}

// MARK: - Distortion

/// Tube, tape, fuzz and digital curves sharing one amount, then a tone lowpass and a DC blocker per
/// channel.
public struct DistortionModule {
  /// One channel's tone lowpass and DC blocker. The channels share coefficients, never state.
  struct Channel {
    var tone = 0.0
    var blockerIn = 0.0
    var blockerOut = 0.0

    @_noAllocation
    mutating func run(_ shaped: Double, coefficient: Double, pole: Double, level: Double) -> Double {
      tone += coefficient * (shaped - tone)
      let blocked = tone - blockerIn + pole * blockerOut
      blockerIn = tone
      blockerOut = blocked
      var output = blocked * level
      if !output.isFinite {
        tone = 0
        blockerIn = 0
        blockerOut = 0
        output = 0
      }
      return output
    }
  }

  let sampleRate: Double
  let blockerPole: Double
  var left = Channel()
  var right = Channel()
  var lastTone = Double.nan
  var toneCoefficient = 1.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    blockerPole = expDSP((-2 * Double.pi * 5) / self.sampleRate)
  }

  /// The selected curve, with the bias applied before it.
  @_noAllocation
  static func shape(_ input: Double, mode: Double, amount: Double, gain: Double, bias: Double) -> Double {
    let driven = (input + bias) * gain
    if mode == 0 {
      // Tube.
      return tanhDSP(driven) - tanhDSP(bias * gain)
    } else if mode == 1 {
      // Tape.
      return (2 * atanDSP(driven)) / Double.pi
    } else if mode == 2 {
      // Fuzz.
      return driven < 0 ? expDSP(driven) - 1 : 1 - expDSP(-driven)
    }
    // Digital: a hard clip, then 12 bits down to 2 as Amount rises.
    let clipped = driven < -1 ? -1 : driven > 1 ? 1 : driven
    let bits = 12 - jsFloor(amount * 10)
    let steps = powDSP(2, bits - 1) - 1
    return jsRound(clipped * steps) / steps
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let amountCv = inlets[2]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let modeParam = params[0]
    let amountParam = params[1]
    let toneParam = params[2]
    let biasParam = params[3]
    let levelParam = params[4]
    for i in 0..<frames {
      var mode = jsRound(Double(modeParam[i]))
      if !(mode > 0) { mode = 0 } else if mode > 3 { mode = 3 }

      var amount = Double(amountParam[i]) + Double(amountCv[i])
      if !(amount > 0) { amount = 0 } else if amount > 1 { amount = 1 }
      let gain = 1 + amount * 31

      var tone = Double(toneParam[i])
      if !(tone > 200) { tone = 200 }
      let ceiling = sampleRate * 0.45
      if tone > ceiling { tone = ceiling }
      if tone != lastTone {
        lastTone = tone
        toneCoefficient = onePole(tone, sampleRate)
      }

      var bias = Double(biasParam[i])
      if !(bias > -0.5) { bias = -0.5 } else if bias > 0.5 { bias = 0.5 }
      var level = Double(levelParam[i])
      if !(level > 0) { level = 0 } else if level > 1.5 { level = 1.5 }

      let shapedLeft = Self.shape(Double(inLeft[i]), mode: mode, amount: amount, gain: gain, bias: bias)
      outLeft[i] = Float(left.run(shapedLeft, coefficient: toneCoefficient, pole: blockerPole, level: level))
      let shapedRight = Self.shape(Double(inRight[i]), mode: mode, amount: amount, gain: gain, bias: bias)
      outRight[i] = Float(
        right.run(shapedRight, coefficient: toneCoefficient, pole: blockerPole, level: level))
    }
  }
}

// MARK: - Cabinet

/// A normalised tanh preamp, a three-band tone stack on two one-pole crossovers, and a speaker: a
/// 70Hz highpass and two lowpass poles at the chosen cabinet's corner.
public struct CabinetModule {
  /// One channel's preamp, tone and cabinet state. The channels share coefficients, never state.
  struct Channel {
    var low = 0.0
    var highBase = 0.0
    var highpassIn = 0.0
    var highpassOut = 0.0
    var cabinet1 = 0.0
    var cabinet2 = 0.0
  }

  let sampleRate: Double
  let lowCoefficient: Double
  let highCoefficient: Double
  let highpassPole: Double
  var left = Channel()
  var right = Channel()
  var lastCabinet = Double.nan
  var cabinetCoefficient = 1.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    lowCoefficient = onePole(250, self.sampleRate)
    highCoefficient = onePole(2500, self.sampleRate)
    highpassPole = expDSP((-2 * Double.pi * 70) / self.sampleRate)
  }

  @_noAllocation
  func run(
    _ state: inout Channel, _ input: Double, drive: Double, driveScale: Double, bassGain: Double,
    midGain: Double, trebleGain: Double, level: Double
  ) -> Double {
    let shaped = tanhDSP(input * drive) * driveScale
    state.low += lowCoefficient * (shaped - state.low)
    state.highBase += highCoefficient * (shaped - state.highBase)
    let low = state.low
    let high = shaped - state.highBase
    let middle = state.highBase - low
    let toned = low * bassGain + middle * midGain + high * trebleGain

    let highpassed = toned - state.highpassIn + highpassPole * state.highpassOut
    state.highpassIn = toned
    state.highpassOut = highpassed

    state.cabinet1 += cabinetCoefficient * (highpassed - state.cabinet1)
    state.cabinet2 += cabinetCoefficient * (state.cabinet1 - state.cabinet2)
    var output = state.cabinet2 * level
    if !output.isFinite {
      state = Channel()
      output = 0
    }
    return output
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let driveCv = inlets[2]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let cabinetParam = params[0]
    let driveParam = params[1]
    let bassParam = params[2]
    let midParam = params[3]
    let trebleParam = params[4]
    let levelParam = params[5]
    for i in 0..<frames {
      var cabinet = jsRound(Double(cabinetParam[i]))
      if !(cabinet > 0) { cabinet = 0 } else if cabinet > 2 { cabinet = 2 }
      if cabinet != lastCabinet {
        lastCabinet = cabinet
        let cutoff: Double = cabinet == 0 ? 6500 : cabinet == 1 ? 4200 : 9500
        cabinetCoefficient = onePole(cutoff, sampleRate)
      }

      var drive = Double(driveParam[i]) + Double(driveCv[i]) * 10
      if !(drive > 0.5) { drive = 0.5 } else if drive > 30 { drive = 30 }
      let driveScale = 1 / tanhDSP(drive)

      var bass = Double(bassParam[i])
      if !(bass > -12) { bass = -12 } else if bass > 12 { bass = 12 }
      var mid = Double(midParam[i])
      if !(mid > -12) { mid = -12 } else if mid > 12 { mid = 12 }
      var treble = Double(trebleParam[i])
      if !(treble > -12) { treble = -12 } else if treble > 12 { treble = 12 }
      let bassGain = powDSP(10, bass / 20)
      let midGain = powDSP(10, mid / 20)
      let trebleGain = powDSP(10, treble / 20)

      var level = Double(levelParam[i])
      if !(level > 0) { level = 0 } else if level > 1.5 { level = 1.5 }

      outLeft[i] = Float(
        run(
          &left, Double(inLeft[i]), drive: drive, driveScale: driveScale, bassGain: bassGain,
          midGain: midGain, trebleGain: trebleGain, level: level))
      outRight[i] = Float(
        run(
          &right, Double(inRight[i]), drive: drive, driveScale: driveScale, bassGain: bassGain,
          midGain: midGain, trebleGain: trebleGain, level: level))
    }
  }
}

// MARK: - EQ

/// Low shelf, peaking mid, high shelf: the RBJ cookbook's biquads in transposed direct form II,
/// recomputed only when a knob has moved.
public struct EQModule {
  /// One band: its coefficients, divided through by a0, and each channel's two states.
  struct Band {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1Left = 0.0, z2Left = 0.0, z1Right = 0.0, z2Right = 0.0

    /// Band 0 is the low shelf, 1 the peaking mid, 2 the high shelf.
    @_noAllocation
    mutating func design(_ band: Int, gainDb: Double, frequency raw: Double, q: Double, sampleRate: Double) {
      var frequency = raw
      if !(frequency > 20) { frequency = 20 }
      let ceiling = (sampleRate / 2) * 0.98
      if frequency > ceiling { frequency = ceiling }

      let w0 = (2 * Double.pi * frequency) / sampleRate
      let cos = cosDSP(w0)
      let sin = sinDSP(w0)
      let amplitude = powDSP(10, gainDb / 40)

      var n0 = 1.0
      var n1 = 0.0
      var n2 = 0.0
      var d0 = 1.0
      var d1 = 0.0
      var d2 = 0.0
      if band == 1 {
        var shape = q
        if !(shape > 0.1) { shape = 0.1 }
        let alpha = sin / (2 * shape)
        n0 = 1 + alpha * amplitude
        n1 = -2 * cos
        n2 = 1 - alpha * amplitude
        d0 = 1 + alpha / amplitude
        d1 = -2 * cos
        d2 = 1 - alpha / amplitude
      } else {
        // `Math.SQRT2`.
        let alpha = (sin / 2) * 1.4142135623730951
        let twoRootAmplitude = 2 * sqrtDSP(amplitude) * alpha
        let plus = amplitude + 1
        let minus = amplitude - 1
        if band == 0 {
          n0 = amplitude * (plus - minus * cos + twoRootAmplitude)
          n1 = 2 * amplitude * (minus - plus * cos)
          n2 = amplitude * (plus - minus * cos - twoRootAmplitude)
          d0 = plus + minus * cos + twoRootAmplitude
          d1 = -2 * (minus + plus * cos)
          d2 = plus + minus * cos - twoRootAmplitude
        } else {
          n0 = amplitude * (plus + minus * cos + twoRootAmplitude)
          n1 = -2 * amplitude * (minus + plus * cos)
          n2 = amplitude * (plus + minus * cos - twoRootAmplitude)
          d0 = plus - minus * cos + twoRootAmplitude
          d1 = 2 * (minus - plus * cos)
          d2 = plus - minus * cos - twoRootAmplitude
        }
      }

      let scale = d0 == 0 || !d0.isFinite ? 1 : 1 / d0
      b0 = n0 * scale
      b1 = n1 * scale
      b2 = n2 * scale
      a1 = d1 * scale
      a2 = d2 * scale
    }

    @_noAllocation
    mutating func run(_ left: inout Double, _ right: inout Double) {
      let outL = b0 * left + z1Left
      z1Left = b1 * left - a1 * outL + z2Left
      z2Left = b2 * left - a2 * outL
      left = outL

      let outR = b0 * right + z1Right
      z1Right = b1 * right - a1 * outR + z2Right
      z2Right = b2 * right - a2 * outR
      right = outR
    }

    @_noAllocation
    mutating func reset() {
      z1Left = 0
      z2Left = 0
      z1Right = 0
      z2Right = 0
    }
  }

  let sampleRate: Double
  var low = Band()
  var mid = Band()
  var high = Band()
  var lastLow = Double.nan
  var lastLowFreq = Double.nan
  var lastMid = Double.nan
  var lastMidFreq = Double.nan
  var lastQ = Double.nan
  var lastHigh = Double.nan
  var lastHighFreq = Double.nan

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let lowParam = params[0]
    let lowFreqParam = params[1]
    let midParam = params[2]
    let midFreqParam = params[3]
    let qParam = params[4]
    let highParam = params[5]
    let highFreqParam = params[6]
    for i in 0..<frames {
      let lowGain = Double(lowParam[i])
      let lowFreq = Double(lowFreqParam[i])
      let midGain = Double(midParam[i])
      let midFreq = Double(midFreqParam[i])
      let q = Double(qParam[i])
      let highGain = Double(highParam[i])
      let highFreq = Double(highFreqParam[i])

      if lowGain != lastLow || lowFreq != lastLowFreq || midGain != lastMid || midFreq != lastMidFreq
        || q != lastQ || highGain != lastHigh || highFreq != lastHighFreq
      {
        lastLow = lowGain
        lastLowFreq = lowFreq
        lastMid = midGain
        lastMidFreq = midFreq
        lastQ = q
        lastHigh = highGain
        lastHighFreq = highFreq
        low.design(0, gainDb: lowGain, frequency: lowFreq, q: q, sampleRate: sampleRate)
        mid.design(1, gainDb: midGain, frequency: midFreq, q: q, sampleRate: sampleRate)
        high.design(2, gainDb: highGain, frequency: highFreq, q: q, sampleRate: sampleRate)
      }

      // Three sections in series. The channels share coefficients, never state.
      var left = Double(inLeft[i])
      var right = Double(inRight[i])
      low.run(&left, &right)
      mid.run(&left, &right)
      high.run(&left, &right)

      // A runaway biquad resets rather than staying poisoned.
      if !left.isFinite || !right.isFinite {
        low.reset()
        mid.reset()
        high.reset()
        left = 0
        right = 0
      }

      outLeft[i] = Float(left)
      outRight[i] = Float(right)
    }
  }
}

// MARK: - Imager

/// Mid/side width in two bands, split by a one-pole lowpass on the side and its exact residual.
public struct ImagerModule {
  let sampleRate: Double
  var sideLow = 0.0
  var lastCrossover = Double.nan
  var coefficient = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let lowWidth = params[0]
    let highWidth = params[1]
    let crossover = params[2]
    for i in 0..<frames {
      var frequency = Double(crossover[i])
      if !(frequency > 20) { frequency = 20 }
      let ceiling = sampleRate * 0.45
      if frequency > ceiling { frequency = ceiling }
      if frequency != lastCrossover {
        lastCrossover = frequency
        coefficient = onePole(frequency, sampleRate)
      }

      let left = Double(inLeft[i])
      let right = Double(inRight[i])
      let mid = (left + right) * 0.5
      let side = (left - right) * 0.5

      sideLow += coefficient * (side - sideLow)
      let sideHigh = side - sideLow
      let widened = sideLow * Double(lowWidth[i]) + sideHigh * Double(highWidth[i])
      var outputLeft = mid + widened
      var outputRight = mid - widened

      // A hostile inlet or param must not poison the crossover for the life of the patch.
      if !outputLeft.isFinite || !outputRight.isFinite || !sideLow.isFinite {
        sideLow = 0
        outputLeft = 0
        outputRight = 0
      }

      outLeft[i] = Float(outputLeft)
      outRight[i] = Float(outputRight)
    }
  }
}

// MARK: - Compressor

/// A peak-detecting compressor with a soft knee in dB, keyed from its sidechain when anything is
/// patched there, and its gain reduction on an outlet.
public struct CompressorModule {
  let sampleRate: Double
  var envelope = 0.0
  var reduction = 0.0
  var lastAttack = Double.nan
  var lastRelease = Double.nan
  var attackCoefficient = 0.0
  var releaseCoefficient = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let sidechain = inlets[1]
    let out = outlets[0]
    let gainOut = outlets[1]
    let thresholdParam = params[0]
    let ratioParam = params[1]
    let attackParam = params[2]
    let releaseParam = params[3]
    let makeupParam = params[4]
    let kneeParam = params[5]

    // Whether anything reaches the sidechain, decided once a block from whether it is all zero.
    var keyed = false
    for i in 0..<frames where sidechain[i] != 0 {
      keyed = true
      break
    }

    for i in 0..<frames {
      let attack = Double(attackParam[i])
      let release = Double(releaseParam[i])
      if attack != lastAttack {
        lastAttack = attack
        attackCoefficient = attack <= 0 ? 0 : powDSP(0.01, 1 / jsMax(1, attack * sampleRate))
      }
      if release != lastRelease {
        lastRelease = release
        releaseCoefficient = release <= 0 ? 0 : powDSP(0.01, 1 / jsMax(1, release * sampleRate))
      }

      let key = keyed ? Double(sidechain[i]) : Double(input[i])
      let peak = key < 0 ? -key : key
      let coefficient = peak > envelope ? attackCoefficient : releaseCoefficient
      envelope = peak + (envelope - peak) * coefficient

      let level = envelope > 1e-5 ? 20 * log10DSP(envelope) : -100
      let threshold = Double(thresholdParam[i])
      let knee = Double(kneeParam[i])
      var ratio = Double(ratioParam[i])
      if ratio < 1 { ratio = 1 }

      let over = level - threshold
      var wanted = 0.0
      if knee > 0 && over > -knee / 2 && over < knee / 2 {
        let into = over + knee / 2
        wanted = ((1 - 1 / ratio) * into * into) / (2 * knee)
      } else if over > 0 {
        wanted = over * (1 - 1 / ratio)
      }

      reduction = wanted > reduction ? wanted : wanted + (reduction - wanted) * releaseCoefficient

      let gain = powDSP(10, (Double(makeupParam[i]) - reduction) / 20)
      out[i] = Float(Double(input[i]) * gain)
      gainOut[i] = Float(reduction / 20)
    }
  }
}

// MARK: - Limiter

/// A stereo-linked limiter with five milliseconds of look-ahead: a delay ring for the audio and a
/// monotonic queue for the window's peak.
public struct LimiterModule {
  let sampleRate: Double
  let lookahead: Int
  let attackCoefficient: Double
  /// Float32, as the reference's rings are: what is delayed, and every queued peak, is rounded.
  let delayLeft: UnsafeMutablePointer<Float>
  let delayRight: UnsafeMutablePointer<Float>
  let peakValues: UnsafeMutablePointer<Float>
  let peakFrames: UnsafeMutablePointer<Int>
  let delayLength: Int
  let queueLength: Int
  var write = 0
  var queueHead = 0
  var queueTail = 0
  var queueCount = 0
  var frame = 0
  var gain = 1.0
  var lastRelease = Double.nan
  var releaseCoefficient = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    lookahead = Int(jsMax(1, jsRound(self.sampleRate * 0.005)))
    attackCoefficient = powDSP(0.01, 1 / Double(lookahead))
    delayLength = lookahead + 1
    // One more than the window: a strictly descending window can keep every peak until the oldest
    // expires.
    queueLength = delayLength + 1
    delayLeft = .allocate(capacity: delayLength)
    delayLeft.initialize(repeating: 0, count: delayLength)
    delayRight = .allocate(capacity: delayLength)
    delayRight.initialize(repeating: 0, count: delayLength)
    peakValues = .allocate(capacity: queueLength)
    peakValues.initialize(repeating: 0, count: queueLength)
    peakFrames = .allocate(capacity: queueLength)
    peakFrames.initialize(repeating: 0, count: queueLength)
  }

  func release() {
    delayLeft.deallocate()
    delayRight.deallocate()
    peakValues.deallocate()
    peakFrames.deallocate()
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let gainReduction = outlets[2]
    let inputGainParam = params[0]
    let ceilingParam = params[1]
    let releaseParam = params[2]
    for i in 0..<frames {
      var inputGainDb = Double(inputGainParam[i])
      if !(inputGainDb > 0) { inputGainDb = 0 } else if inputGainDb > 24 { inputGainDb = 24 }
      let inputGain = powDSP(10, inputGainDb / 20)
      var left = Double(inLeft[i]) * inputGain
      var right = Double(inRight[i]) * inputGain
      if !left.isFinite { left = 0 }
      if !right.isFinite { right = 0 }

      delayLeft[write] = Float(left)
      delayRight[write] = Float(right)

      let leftPeak = left < 0 ? -left : left
      let rightPeak = right < 0 ? -right : right
      let peak = leftPeak > rightPeak ? leftPeak : rightPeak

      // Smaller peaks behind this one can never be the maximum again.
      while queueCount > 0 {
        let last = queueTail == 0 ? queueLength - 1 : queueTail - 1
        if Double(peakValues[last]) > peak { break }
        queueTail = last
        queueCount -= 1
      }
      peakValues[queueTail] = Float(peak)
      peakFrames[queueTail] = frame
      queueTail += 1
      if queueTail >= queueLength { queueTail = 0 }
      queueCount += 1

      let oldest = frame - lookahead
      while queueCount > 0 && peakFrames[queueHead] < oldest {
        queueHead += 1
        if queueHead >= queueLength { queueHead = 0 }
        queueCount -= 1
      }

      var ceilingDb = Double(ceilingParam[i])
      if !(ceilingDb > -12) { ceilingDb = -12 } else if ceilingDb > 0 { ceilingDb = 0 }
      let ceiling = powDSP(10, ceilingDb / 20)
      let windowPeak = queueCount > 0 ? Double(peakValues[queueHead]) : 0
      let wanted = windowPeak > ceiling ? ceiling / windowPeak : 1

      var release = Double(releaseParam[i])
      if !(release > 0.01) { release = 0.01 } else if release > 1 { release = 1 }
      if release != lastRelease {
        lastRelease = release
        releaseCoefficient = powDSP(0.01, 1 / jsMax(1, release * sampleRate))
      }

      if wanted < gain {
        gain = wanted + (gain - wanted) * attackCoefficient
      } else {
        gain = wanted + (gain - wanted) * releaseCoefficient
      }

      var read = write + 1
      if read >= delayLength { read = 0 }
      var limitedLeft = Double(delayLeft[read]) * gain
      var limitedRight = Double(delayRight[read]) * gain
      if limitedLeft > ceiling {
        limitedLeft = ceiling
      } else if limitedLeft < -ceiling {
        limitedLeft = -ceiling
      }
      if limitedRight > ceiling {
        limitedRight = ceiling
      } else if limitedRight < -ceiling {
        limitedRight = -ceiling
      }

      outLeft[i] = Float(limitedLeft)
      outRight[i] = Float(limitedRight)
      gainReduction[i] = Float(1 - gain)

      write = read
      frame += 1
    }
  }
}

// MARK: - Definitions

extension RackModules {
  static let shapingDefs: [ModuleDef] = [
    driveDef, distortionDef, cabinetDef, eqDef, imagerDef, compressorDef, limiterDef,
  ]

  static func makeShaping(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo)
    -> ShapingProcessor?
  {
    switch type {
    case "drive": .drive(DriveModule(sampleRate: sampleRate))
    case "distortion": .distortion(DistortionModule(sampleRate: sampleRate))
    case "cabinet": .cabinet(CabinetModule(sampleRate: sampleRate))
    case "eq": .eq(EQModule(sampleRate: sampleRate))
    case "imager": .imager(ImagerModule(sampleRate: sampleRate))
    case "compressor": .compressor(CompressorModule(sampleRate: sampleRate))
    case "limiter": .limiter(LimiterModule(sampleRate: sampleRate))
    default: nil
    }
  }

  static let driveDef = ModuleDef(
    type: "drive", name: "Drive", inlets: [Port("in", "In"), Port("cv", "CV")], outlets: [Port("out", "Out")],
    params: [
      ParamDef("drive", "Drive", min: 0.1, max: 40, default: 2),
      ParamDef("bias", "Bias", min: -1, max: 1, default: 0),
    ])

  static let distortionDef: ModuleDef = {
    var def = ModuleDef(
      type: "distortion", name: "Distortion",
      inlets: [Port("in", "In", stereo: true), Port("amount", "Amount")],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("mode", "Mode", min: 0, max: 3, default: 0, stepped: true),
        ParamDef("amount", "Amount", min: 0, max: 1, default: 0.25),
        ParamDef("tone", "Tone Hz", min: 200, max: 18000, default: 8000),
        ParamDef("bias", "Bias", min: -0.5, max: 0.5, default: 0),
        ParamDef("level", "Level", min: 0, max: 1.5, default: 0.8),
      ])
    def.poly = false
    return def
  }()

  static let cabinetDef: ModuleDef = {
    var def = ModuleDef(
      type: "cabinet", name: "Amp / Cab", inlets: [Port("in", "In", stereo: true), Port("drive", "Drive")],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("cabinet", "Cab", min: 0, max: 2, default: 0, stepped: true),
        ParamDef("drive", "Drive", min: 0.5, max: 30, default: 2),
        ParamDef("bass", "Bass", min: -12, max: 12, default: 0),
        ParamDef("mid", "Mid", min: -12, max: 12, default: 0),
        ParamDef("treble", "Treble", min: -12, max: 12, default: 0),
        ParamDef("level", "Level", min: 0, max: 1.5, default: 0.8),
      ])
    def.poly = false
    return def
  }()

  static let eqDef = ModuleDef(
    type: "eq", name: "EQ", inlets: [Port("in", "In", stereo: true)],
    outlets: [Port("out", "Out", stereo: true)],
    params: [
      ParamDef("low", "Low", min: -18, max: 18, default: 0),
      ParamDef("lowFreq", "Low Hz", min: 40, max: 500, default: 120),
      ParamDef("mid", "Mid", min: -18, max: 18, default: 0),
      ParamDef("midFreq", "Mid Hz", min: 100, max: 8000, default: 1000),
      ParamDef("q", "Q", min: 0.3, max: 8, default: 0.9),
      ParamDef("high", "High", min: -18, max: 18, default: 0),
      ParamDef("highFreq", "High Hz", min: 1500, max: 16000, default: 6000),
    ])

  static let imagerDef: ModuleDef = {
    var def = ModuleDef(
      type: "imager", name: "Stereo Imager", inlets: [Port("in", "In", stereo: true)],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("lowWidth", "Low Width", min: 0, max: 2, default: 1),
        ParamDef("highWidth", "High Width", min: 0, max: 2, default: 1),
        ParamDef("crossover", "X-Over Hz", min: 60, max: 2000, default: 250),
      ])
    def.poly = false
    return def
  }()

  static let compressorDef = ModuleDef(
    type: "compressor", name: "Comp", inlets: [Port("in", "In"), Port("key", "Key")],
    outlets: [Port("out", "Out"), Port("gain", "GR")],
    params: [
      ParamDef("threshold", "Thresh", min: -60, max: 0, default: -18),
      ParamDef("ratio", "Ratio", min: 1, max: 20, default: 4),
      ParamDef("attack", "Attack", min: 0.0001, max: 0.2, default: 0.005),
      ParamDef("release", "Release", min: 0.005, max: 1, default: 0.12),
      ParamDef("makeup", "Makeup", min: 0, max: 24, default: 0),
      ParamDef("knee", "Knee", min: 0, max: 24, default: 6),
    ])

  static let limiterDef: ModuleDef = {
    var def = ModuleDef(
      type: "limiter", name: "Limiter", inlets: [Port("in", "In", stereo: true)],
      outlets: [Port("out", "Out", stereo: true), Port("gain", "GR")],
      params: [
        ParamDef("inputGain", "Input dB", min: 0, max: 24, default: 0),
        ParamDef("ceiling", "Ceiling dB", min: -12, max: 0, default: -0.5),
        ParamDef("release", "Release", min: 0.01, max: 1, default: 0.12),
      ])
    def.poly = false
    return def
  }()
}
