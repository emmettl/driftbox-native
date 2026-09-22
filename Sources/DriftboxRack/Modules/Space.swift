import DriftboxDSP

// The Space family: ping-pong, phaser, the fdn reverb and the looper, each a line-for-line port of
// its file in `driftbox/packages/rack/src/modules`. The family's processors are one enum here,
// behind one case of `RackProcessor`, so its modules can be added without touching anyone else's.
// The reverb, the largest, is in `SpaceReverb.swift`.

public enum SpaceProcessor {
  case pingPong(PingPong)
  case phaser(Phaser)
  case reverb(ReverbModule)
  case looper(Looper)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .pingPong(var module):
      module.process(inlets, outlets, params, context)
      self = .pingPong(module)
    case .phaser(var module):
      module.process(inlets, outlets, params, context)
      self = .phaser(module)
    case .reverb(var module):
      module.process(inlets, outlets, params, context)
      self = .reverb(module)
    case .looper(var module):
      module.process(inlets, outlets, params, context)
      self = .looper(module)
    }
  }

  func meter() -> MeterReading? {
    switch self {
    case .looper(let module): module.meter()
    default: nil
    }
  }

  mutating func release() {
    switch self {
    case .pingPong(let module):
      module.left.deallocate()
      module.right.deallocate()
    case .phaser(let module): module.state.deallocate()
    case .reverb(let module): module.release()
    case .looper(let module):
      module.left.deallocate()
      module.right.deallocate()
    }
  }
}

/// A mono-in, stereo-out delay whose repeats alternate left and right, wet only.
public struct PingPong {
  let sampleRate: Double
  /// Float32, as the reference's lines are.
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>
  let length: Int
  var write = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    length = Int(jsCeil(self.sampleRate * 2)) + 4
    left = .allocate(capacity: length)
    left.initialize(repeating: 0, count: length)
    right = .allocate(capacity: length)
    right.initialize(repeating: 0, count: length)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let timeCv = inlets[1]
    let feedbackCv = inlets[2]
    let outLeft = outlets[0]
    let outRight = outlets[1]
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
      let delayedLeft: Double
      let delayedRight: Double
      if read.isNaN {
        // The reference indexes its lines with NaN, reads `undefined`, and carries NaN on.
        delayedLeft = .nan
        delayedRight = .nan
      } else {
        // Never negative, so truncating is the reference's `Math.floor`.
        let index = Int(read)
        let fraction = read - Double(index)
        let next = index + 1 < length ? index + 1 : 0
        let l = Double(left[index])
        let r = Double(right[index])
        delayedLeft = l + (Double(left[next]) - l) * fraction
        delayedRight = r + (Double(right[next]) - r) * fraction
      }
      outLeft[i] = Float(delayedLeft)
      outRight[i] = Float(delayedRight)

      var fb = Double(feedback[i]) + Double(feedbackCv[i])
      if fb < 0 { fb = 0 } else if fb > 0.98 { fb = 0.98 }

      // Cross feedback: input enters left, then each line writes what the other just read.
      var writtenLeft = Double(input[i]) + delayedRight * fb
      var writtenRight = delayedLeft * fb
      if !(writtenLeft > -8 && writtenLeft < 8) {
        writtenLeft = writtenLeft > 0 ? 8 : writtenLeft < 0 ? -8 : 0
      }
      if !(writtenRight > -8 && writtenRight < 8) {
        writtenRight = writtenRight > 0 ? 8 : writtenRight < 0 ? -8 : 0
      }
      left[write] = Float(writtenLeft)
      right[write] = Float(writtenRight)

      write += 1
      if write >= length { write = 0 }
    }
  }
}

/// Six swept first-order allpass stages a side, mixed back with the dry.
public struct Phaser {
  let sampleRate: Double
  /// Twelve doubles: the left channel's six stages, then the right's. The reference's are plain
  /// number arrays, so doubles.
  let state: UnsafeMutablePointer<Double>
  var phase = 0.0
  var feedbackLeft = 0.0
  var feedbackRight = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    state = .allocate(capacity: 12)
    state.initialize(repeating: 0, count: 12)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inLeft = inlets[0]
    let inRight = inlets[1]
    let sweepCv = inlets[2]
    let outLeft = outlets[0]
    let outRight = outlets[1]
    let rateParam = params[0]
    let centerParam = params[1]
    let depthParam = params[2]
    let feedbackParam = params[3]
    let mixParam = params[4]

    let leftState = state
    let rightState = state + 6
    let nyquist = sampleRate / 2
    var phase = self.phase
    var feedbackLeft = self.feedbackLeft
    var feedbackRight = self.feedbackRight

    for i in 0..<frames {
      var rate = Double(rateParam[i])
      if !(rate > 0.02) { rate = 0.02 } else if rate > 8 { rate = 8 }

      var center = Double(centerParam[i])
      if !(center > 20) { center = 20 } else if center > nyquist * 0.45 { center = nyquist * 0.45 }

      var depth = Double(depthParam[i])
      if !(depth > 0) { depth = 0 } else if depth > 1 { depth = 1 }
      let span = depth * 3
      let radians = phase * 2 * Double.pi
      let shift = Double(sweepCv[i])

      var frequencyLeft = center * exp2(sinDSP(radians) * span + shift)
      var frequencyRight = center * exp2(sinDSP(radians + Double.pi / 2) * span + shift)
      if !(frequencyLeft > 20) {
        frequencyLeft = 20
      } else if frequencyLeft > nyquist * 0.9 {
        frequencyLeft = nyquist * 0.9
      }
      if !(frequencyRight > 20) {
        frequencyRight = 20
      } else if frequencyRight > nyquist * 0.9 {
        frequencyRight = nyquist * 0.9
      }

      let tangentLeft = tanDSP((Double.pi * frequencyLeft) / sampleRate)
      let tangentRight = tanDSP((Double.pi * frequencyRight) / sampleRate)
      let coefficientLeft = (tangentLeft - 1) / (tangentLeft + 1)
      let coefficientRight = (tangentRight - 1) / (tangentRight + 1)

      var feedback = Double(feedbackParam[i])
      if !(feedback > -0.9) { feedback = -0.9 } else if feedback > 0.9 { feedback = 0.9 }

      var wetLeft = Double(inLeft[i]) + feedbackLeft * feedback
      var wetRight = Double(inRight[i]) + feedbackRight * feedback
      for stage in 0..<6 {
        let nextLeft = coefficientLeft * wetLeft + leftState[stage]
        leftState[stage] = wetLeft - coefficientLeft * nextLeft
        wetLeft = nextLeft

        let nextRight = coefficientRight * wetRight + rightState[stage]
        rightState[stage] = wetRight - coefficientRight * nextRight
        wetRight = nextRight
      }

      feedbackLeft = wetLeft
      feedbackRight = wetRight

      var mix = Double(mixParam[i])
      if !(mix > 0) { mix = 0 } else if mix > 1 { mix = 1 }
      var outputLeft = Double(inLeft[i]) * (1 - mix) + wetLeft * mix
      var outputRight = Double(inRight[i]) * (1 - mix) + wetRight * mix

      if !outputLeft.isFinite || !outputRight.isFinite {
        for stage in 0..<6 {
          leftState[stage] = 0
          rightState[stage] = 0
        }
        feedbackLeft = 0
        feedbackRight = 0
        outputLeft = 0
        outputRight = 0
      }

      outLeft[i] = Float(outputLeft)
      outRight[i] = Float(outputRight)
      phase += rate / sampleRate
      phase -= jsFloor(phase)
    }

    self.phase = phase
    self.feedbackLeft = feedbackLeft
    self.feedbackRight = feedbackRight
  }
}

/// A stereo performance looper: record, play, overdub, stop and clear, into thirty seconds
/// allocated up front. It follows its Transport knob, not the rack's transport.
public struct Looper {
  let sampleRate: Double
  let maximum: Int
  /// Float32, as the reference's capture is.
  let left: UnsafeMutablePointer<Float>
  let right: UnsafeMutablePointer<Float>
  var position = 0
  var length = 0
  var lastMode = -1
  var captureMode = 0
  var lastClear = Double.nan
  /// The last block's mean square. The reference keeps its root, but only the meter reads it,
  /// so the root is taken there, off the render path.
  var meanSquare = 0.0
  var peak = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    maximum = max(1, Int(jsRound(self.sampleRate * 30)))
    left = .allocate(capacity: maximum)
    left.initialize(repeating: 0, count: maximum)
    right = .allocate(capacity: maximum)
    right.initialize(repeating: 0, count: maximum)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let inputLeft = inlets[0]
    let inputRight = inlets[1]
    let outputLeft = outlets[0]
    let outputRight = outlets[1]
    let rounded = jsRound(Double(params[0][0]))
    let mode: Int
    if !(rounded > 0) { mode = 0 } else if rounded > 3 { mode = 3 } else { mode = Int(rounded) }

    let clear = params[4][0] >= 0.5 ? 1.0 : 0.0
    if lastClear.isNaN {
      lastClear = clear
    } else if clear != lastClear {
      lastClear = clear
      position = 0
      length = 0
      captureMode = 0
      // A clear while Record remains selected begins a fresh first pass in this block.
      lastMode = -1
    }

    if captureMode != 0 && mode != captureMode {
      length = max(1, min(maximum, position))
      position = 0
      captureMode = 0
    }
    if mode != lastMode {
      if mode == 1 {
        position = 0
        length = 0
        captureMode = 1
      } else if mode == 3 && length == 0 {
        position = 0
        captureMode = 3
      } else if mode == 0 || lastMode == 0 {
        position = 0
      }
      lastMode = mode
    }

    let feedbackParam = params[1]
    let dryParam = params[2]
    let loopParam = params[3]
    var squares = 0.0
    var peak = 0.0
    for i in 0..<frames {
      let inL = inputLeft[i].isFinite ? Double(inputLeft[i]) : 0
      let inR = inputRight[i].isFinite ? Double(inputRight[i]) : 0
      let dry = Double(dryParam[i])
      let loop = Double(loopParam[i])
      var outL = inL * dry
      var outR = inR * dry

      // As the reference has it, Stop (mode 0) matches the idle capture mode 0 and so records too.
      if captureMode == mode {
        if position < maximum {
          left[position] = Float(inL)
          right[position] = Float(inR)
          position += 1
          length = position
        }
      } else if (mode == 2 || mode == 3) && length > 0 {
        let oldL = Double(left[position])
        let oldR = Double(right[position])
        outL += oldL * loop
        outR += oldR * loop
        if mode == 3 {
          let feedback = Double(feedbackParam[i])
          left[position] = Float(oldL * feedback + inL)
          right[position] = Float(oldR * feedback + inR)
        }
        position += 1
        if position >= length { position = 0 }
      }

      outputLeft[i] = outL.isFinite ? Float(outL) : 0
      outputRight[i] = outR.isFinite ? Float(outR) : 0
      let magnitudeL = outL < 0 ? -outL : outL
      let magnitudeR = outR < 0 ? -outR : outR
      squares += (outL * outL + outR * outR) * 0.5
      if magnitudeL > peak { peak = magnitudeL }
      if magnitudeR > peak { peak = magnitudeR }
    }
    meanSquare = frames > 0 ? squares / Double(frames) : 0
    self.peak = peak
  }

  func meter() -> MeterReading {
    let level = meanSquare.squareRoot()
    var waveform = [Float](repeating: 0, count: 48)
    if length > 0 {
      for point in 0..<waveform.count {
        let index = min(length - 1, Int(jsFloor(Double(point * length) / Double(waveform.count))))
        var sample = (Double(left[index]) + Double(right[index])) * 0.5
        if sample < -1 { sample = -1 } else if sample > 1 { sample = 1 }
        waveform[point] = Float(sample)
      }
    }
    return MeterReading(
      level: level, peak: peak, envelope: level, waveform: waveform,
      loopPosition: length > 0 ? Double(position) / Double(length) : 0,
      loopSeconds: Double(length) / sampleRate)
  }
}

extension RackModules {
  static let spaceDefs: [ModuleDef] = [pingPong, phaser, reverb, looper]

  static func makeSpace(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo) -> SpaceProcessor? {
    switch type {
    case "ping-pong": .pingPong(PingPong(sampleRate: sampleRate))
    case "phaser": .phaser(Phaser(sampleRate: sampleRate))
    case "reverb": .reverb(ReverbModule(sampleRate: sampleRate))
    case "looper": .looper(Looper(sampleRate: sampleRate))
    default: nil
    }
  }

  static let pingPong: ModuleDef = {
    var def = ModuleDef(
      type: "ping-pong", name: "Ping-Pong Delay",
      inlets: [Port("in", "In"), Port("time", "Time"), Port("fb", "FB")],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("time", "Time", min: 0.0003, max: 2, default: 0.25),
        ParamDef("feedback", "FB", min: 0, max: 0.98, default: 0.55),
      ])
    def.poly = false
    return def
  }()

  static let phaser: ModuleDef = {
    var def = ModuleDef(
      type: "phaser", name: "Phaser",
      inlets: [Port("in", "In", stereo: true), Port("sweep", "Sweep")],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("rate", "Rate", min: 0.02, max: 8, default: 0.35),
        ParamDef("center", "Center Hz", min: 80, max: 4000, default: 800),
        ParamDef("depth", "Depth", min: 0, max: 1, default: 0.65),
        ParamDef("feedback", "Feedback", min: -0.9, max: 0.9, default: 0.25),
        ParamDef("mix", "Mix", min: 0, max: 1, default: 0.5),
      ])
    def.poly = false
    return def
  }()

  static let reverb: ModuleDef = {
    var def = ModuleDef(
      type: "reverb", name: "Reverb", inlets: [Port("in", "In")],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("size", "Size", min: 0.1, max: 1, default: 0.7),
        ParamDef("decay", "Decay", min: 0, max: 0.98, default: 0.82),
        ParamDef("damp", "Damp", min: 0, max: 0.99, default: 0.4),
        ParamDef("mix", "Mix", min: 0, max: 1, default: 0.25),
        ParamDef("algorithm", "Algorithm", min: 0, max: 3, default: 0, stepped: true),
        ParamDef("lowCut", "Low Cut", min: 20, max: 2000, default: 20),
        ParamDef("highCut", "High Cut", min: 1000, max: 18000, default: 18000),
        ParamDef("gate", "Gate", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("gateThresh", "Thresh", min: 0, max: 1, default: 0.05),
        ParamDef("gateHold", "Hold", min: 0, max: 2, default: 0.15),
        ParamDef("gateRelease", "Release", min: 0.001, max: 1, default: 0.02),
      ])
    def.poly = false
    return def
  }()

  static let looper: ModuleDef = {
    var def = ModuleDef(
      type: "looper", name: "Loop Station", inlets: [Port("in", "In", stereo: true)],
      outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("mode", "Transport", min: 0, max: 3, default: 0, stepped: true),
        ParamDef("feedback", "Feedback", min: 0, max: 1, default: 0.85),
        ParamDef("dry", "Dry", min: 0, max: 1, default: 1),
        ParamDef("loop", "Loop", min: 0, max: 1, default: 1),
        ParamDef("clear", "Clear", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.poly = false
    return def
  }()
}
