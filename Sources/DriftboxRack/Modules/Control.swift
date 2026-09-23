import DriftboxDSP

// The control family: follower, quantizer, meter, tuner, line mixer and Combinator, each a
// line-for-line port of its file in `driftbox/packages/rack/src/modules`. The family's processors
// are one enum here, behind one case of `RackProcessor`, so its modules can be added without
// touching anyone else's. The Combinator's routings are not here: they are applied to the patch
// when it is compiled, in `Modulation.swift`.

public enum ControlProcessor {
  case follower(Follower)
  case quantizer(Quantizer)
  case meter(VUMeter)
  case tuner(Tuner)
  case lineMixer
  case combi

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .follower(var module):
      module.process(inlets, outlets, params, context)
      self = .follower(module)
    case .quantizer(var module):
      module.process(inlets, outlets, params, context)
      self = .quantizer(module)
    case .meter(var module):
      module.process(inlets, outlets, params, context)
      self = .meter(module)
    case .tuner(var module):
      module.process(inlets, outlets, params, context)
      self = .tuner(module)
    case .lineMixer: LineMixer.process(inlets, outlets, params, context)
    case .combi: Combinator.process(inlets, outlets, params, context)
    }
  }

  func meter() -> MeterReading? {
    switch self {
    case .meter(let module): module.meter()
    case .tuner(let module): module.meter()
    default: nil
    }
  }

  mutating func release() {
    switch self {
    case .meter(let module): module.waveform.deallocate()
    case .tuner(let module): module.release()
    default: break
    }
  }
}

// MARK: - Follower

/// An envelope follower: audio in, its own shape out as CV, and a gate with hysteresis.
public struct Follower {
  let sampleRate: Double
  var envelope = 0.0
  /// Held across blocks, so a signal sitting on the threshold does not chatter at the block rate.
  var open = false
  var lastAttack = Double.nan
  var lastRelease = Double.nan
  var attackCoefficient = 0.0
  var releaseCoefficient = 0.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let envOut = outlets[0]
    let gateOut = outlets[1]
    let attackParam = params[0]
    let releaseParam = params[1]
    let gainParam = params[2]
    let thresholdParam = params[3]
    for i in 0..<frames {
      let attack = Double(attackParam[i])
      if attack != lastAttack {
        lastAttack = attack
        attackCoefficient = attack <= 0 ? 0 : powDSP(0.01, 1 / max(1, attack * sampleRate))
      }
      let release = Double(releaseParam[i])
      if release != lastRelease {
        lastRelease = release
        releaseCoefficient = release <= 0 ? 0 : powDSP(0.01, 1 / max(1, release * sampleRate))
      }

      let sample = Double(input[i])
      let peak = sample < 0 ? -sample : sample
      let coefficient = peak > envelope ? attackCoefficient : releaseCoefficient
      envelope = peak + (envelope - peak) * coefficient

      let value = envelope * Double(gainParam[i])
      // Clamped at the outlet, not in the state.
      envOut[i] = Float(value > 4 ? 4 : value)

      // Hysteresis: closing at four fifths of the opening level.
      let threshold = Double(thresholdParam[i])
      if open {
        if value < threshold * 0.8 { open = false }
      } else if value >= threshold {
        open = true
      }
      gateOut[i] = open ? 1 : 0
    }
  }
}

// MARK: - Quantizer

/// Snap a pitch CV to a scale, with a trigger whenever the note it lands on changes.
public struct Quantizer {
  let trigSamples: Int
  var lastNote = Double.nan
  var trigLeft = 0

  init(sampleRate: Double) {
    trigSamples = Int(max(1, jsCeil(sampleRate * 0.001)))
  }

  /// The reference's six scales, a bit per semitone. Walking the bits upward visits the degrees
  /// in the ascending order its arrays list them, which is what breaks a tie between two.
  @_noAllocation
  static func scaleMask(_ which: Int) -> Int {
    switch which {
    case 0: 0b1111_1111_1111  // chromatic
    case 1: 0b1010_1011_0101  // major: 0 2 4 5 7 9 11
    case 2: 0b0101_1010_1101  // natural minor: 0 2 3 5 7 8 10
    case 3: 0b0100_1010_1001  // minor pentatonic: 0 3 5 7 10
    case 4: 0b0110_1010_1101  // dorian: 0 2 3 5 7 9 10
    default: 0b0101_0101_0101  // whole tone: 0 2 4 6 8 10
    }
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let out = outlets[0]
    let trigOut = outlets[1]
    let scale = params[0]
    let root = params[1]
    for i in 0..<frames {
      var which = truncated(scale[i])
      if which < 0 { which = 0 } else if which >= 6 { which = 5 }
      let mask = Self.scaleMask(which)
      let offset = jsRound(Double(root[i]))

      // Octaves in, semitones to work in, octaves out.
      let semitones = Double(input[i]) * 12 - offset
      let octave = jsFloor(semitones / 12)
      let within = semitones - octave * 12

      // Every scale's first degree is its root, 0.
      var best = 0.0
      var closest = abs(within - 0)
      for degree in 1..<12 where mask & (1 << degree) != 0 {
        let distance = abs(within - Double(degree))
        if distance < closest {
          closest = distance
          best = Double(degree)
        }
      }
      // The root of the octave above is a candidate too.
      if abs(within - 12) < closest { best = 12 }

      let note = offset + octave * 12 + best
      out[i] = Float(note / 12)

      if note != lastNote {
        lastNote = note
        trigLeft = trigSamples
      }
      if trigLeft > 0 {
        trigLeft -= 1
        trigOut[i] = 1
      } else {
        trigOut[i] = 0
      }
    }
  }
}

// MARK: - Meter

/// A meter in a cable: the signal through untouched, and the needle's ballistic envelope as CV.
public struct VUMeter {
  static let points = 48
  let sampleRate: Double
  var envelope = 0.0
  var blockSquares = 0.0
  var blockFrames = 0
  var peak = 0.0
  /// Float32, as the reference's is; the only copy is made when `meter()` is asked.
  let waveform: UnsafeMutablePointer<Float>
  var lastRelease = Double.nan
  var releaseCoefficient = 0.0
  let attackCoefficient: Double

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    // Ten milliseconds catches a transient without making a needle twitch at audio rate.
    attackCoefficient = powDSP(0.01, 1 / max(1, 0.01 * sampleRate))
    waveform = .allocate(capacity: Self.points)
    waveform.initialize(repeating: 0, count: Self.points)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let thru = outlets[0]
    let env = outlets[1]
    let gain = params[0]
    let release = params[1]

    var squares = 0.0
    var blockPeak = 0.0
    for i in 0..<frames {
      let sample = Double(input[i])
      thru[i] = input[i]

      let sensitivity = Double(gain[i])
      let measured = (sample < 0 ? -sample : sample) * sensitivity
      squares += measured * measured
      if measured > blockPeak { blockPeak = measured }

      let seconds = Double(release[i])
      if seconds != lastRelease {
        lastRelease = seconds
        releaseCoefficient = seconds <= 0 ? 0 : powDSP(0.01, 1 / max(1, seconds * sampleRate))
      }
      let coefficient = measured > envelope ? attackCoefficient : releaseCoefficient
      envelope = measured + (envelope - measured) * coefficient
      env[i] = Float(envelope > 4 ? 4 : envelope)
    }

    blockSquares = squares
    blockFrames = frames
    peak = blockPeak

    // Forty-eight points picked evenly from the latest block.
    let points = Self.points
    for point in 0..<points {
      let index = min(frames - 1, (point * frames) / points)
      let sensitivity = frames > 0 ? Double(gain[max(0, index)]) : 1
      var sample = frames > 0 ? Double(input[max(0, index)]) * sensitivity : 0
      if sample < -1 { sample = -1 } else if sample > 1 { sample = 1 }
      waveform[point] = Float(sample)
    }
  }

  /// The last block's RMS, taken when asked: see `Tuner.level`.
  var level: Double { blockLevel(blockSquares, blockFrames) }

  func meter() -> MeterReading {
    MeterReading(
      level: level, peak: peak, envelope: envelope,
      waveform: Array(UnsafeBufferPointer(start: waveform, count: Self.points)))
  }
}

// MARK: - Tuner

/// A chromatic tuner with a transparent through path. Pitch is found by normalised
/// autocorrelation over a rolling, downsampled window, when the faceplate asks for it.
public struct Tuner {
  static let historyLength = 2048
  static let analysisLength = 1024
  static let points = 48
  let sampleRate: Double
  let decimation: Int
  let analysisRate: Double
  /// All Float32, as the reference's buffers are, so what the analysis reads is rounded as its is.
  let history: UnsafeMutablePointer<Float>
  let analysis: UnsafeMutablePointer<Float>
  let correlations: UnsafeMutablePointer<Float>
  let correlationCount: Int
  let lowpassCoefficient: Double
  let waveform: UnsafeMutablePointer<Float>
  var write = 0
  var filled = 0
  var phase = 0
  var lowpass = 0.0
  var blockSquares = 0.0
  var blockFrames = 0
  var peak = 0.0

  /// The last block's RMS. Taken when asked rather than per block, because a square root is a
  /// call the render path may not make; the arithmetic is the reference's either way.
  var level: Double { blockLevel(blockSquares, blockFrames) }

  init(sampleRate rate: Double) {
    sampleRate = rate > 0 ? rate : 44100
    decimation = Int(max(1, jsFloor(sampleRate / 8000)))
    analysisRate = sampleRate / Double(decimation)
    correlationCount = Int(jsCeil(analysisRate / 45)) + 2
    lowpassCoefficient = 1 - expDSP((-2 * Double.pi * 1800) / sampleRate)
    history = .allocate(capacity: Self.historyLength)
    history.initialize(repeating: 0, count: Self.historyLength)
    analysis = .allocate(capacity: Self.analysisLength)
    analysis.initialize(repeating: 0, count: Self.analysisLength)
    correlations = .allocate(capacity: correlationCount)
    correlations.initialize(repeating: 0, count: correlationCount)
    waveform = .allocate(capacity: Self.points)
    waveform.initialize(repeating: 0, count: Self.points)
  }

  func release() {
    history.deallocate()
    analysis.deallocate()
    correlations.deallocate()
    waveform.deallocate()
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let input = inlets[0]
    let thru = outlets[0]
    let mute = params[1]
    let length = Self.historyLength
    var squares = 0.0
    var blockPeak = 0.0

    for i in 0..<frames {
      let sample = input[i].isFinite ? Double(input[i]) : 0
      thru[i] = mute[i] >= 0.5 ? 0 : Float(sample)
      let magnitude = sample < 0 ? -sample : sample
      squares += sample * sample
      if magnitude > blockPeak { blockPeak = magnitude }

      lowpass += lowpassCoefficient * (sample - lowpass)
      if phase == 0 {
        history[write] = Float(lowpass)
        write = (write + 1) % length
        if filled < length { filled += 1 }
      }
      phase += 1
      if phase >= decimation { phase = 0 }
    }

    blockSquares = squares
    blockFrames = frames
    peak = blockPeak

    let points = Self.points
    for point in 0..<points {
      let index = min(frames - 1, (point * frames) / points)
      var sample = frames > 0 ? Double(input[max(0, index)]) : 0
      if sample < -1 { sample = -1 } else if sample > 1 { sample = 1 }
      waveform[point] = Float(sample)
    }
  }

  /// The reference detects on the first ask after a block and caches the answer until the next
  /// block. Detection reads nothing but what a block changes, so running it on every ask gives the
  /// same answer without the processor having to mutate here.
  func meter() -> MeterReading {
    let (frequency, clarity) = detect()
    return MeterReading(
      level: level, peak: peak, envelope: level,
      waveform: Array(UnsafeBufferPointer(start: waveform, count: Self.points)), frequency: frequency,
      clarity: clarity)
  }

  /// Frequency and clarity; a frequency of zero is no credible note.
  func detect() -> (frequency: Double, clarity: Double) {
    let length = Self.historyLength
    // A quiet input is more usefully blank than a confident reading from the old tail.
    if level < 0.003 || filled < 256 { return (0, 0) }

    let count = min(filled, Self.analysisLength)
    let start = (write - count + length) % length
    var mean = 0.0
    for i in 0..<count {
      let sample = history[(start + i) % length]
      analysis[i] = sample
      mean += Double(sample)
    }
    mean /= Double(count)
    for i in 0..<count { analysis[i] = Float(Double(analysis[i]) - mean) }

    let minimumLag = Int(max(2, jsFloor(analysisRate / 2000)))
    let maximumLag = Int(
      min(Double(correlationCount - 2), jsFloor(analysisRate / 55), jsFloor(Double(count) / 3)))
    if maximumLag <= minimumLag + 1 { return (0, 0) }

    var best = 0.0
    for lag in minimumLag...maximumLag {
      var product = 0.0
      var energyA = 0.0
      var energyB = 0.0
      let samples = count - lag
      for i in 0..<samples {
        let a = Double(analysis[i])
        let b = Double(analysis[i + lag])
        product += a * b
        energyA += a * a
        energyB += b * b
      }
      let denominator = (energyA * energyB).squareRoot()
      let correlation = denominator > 1e-12 ? product / denominator : 0
      correlations[lag] = correlation.isFinite ? Float(correlation) : 0
      if Double(correlations[lag]) > best { best = Double(correlations[lag]) }
    }

    if best < 0.55 { return (0, max(0, best)) }

    // The first strong local peak names the fundamental rather than a subharmonic.
    let threshold = max(0.62, best * 0.88)
    var chosen = 0
    var lag = minimumLag + 1
    while lag < maximumLag {
      let here = Double(correlations[lag])
      if here >= threshold && here >= Double(correlations[lag - 1]) && here > Double(correlations[lag + 1]) {
        chosen = lag
        break
      }
      lag += 1
    }
    if chosen == 0 {
      for lag in minimumLag...maximumLag where Double(correlations[lag]) == best {
        chosen = lag
        break
      }
    }

    // Parabolic interpolation for the fraction of a sample a cents display needs.
    let left = Double(correlations[max(minimumLag, chosen - 1)])
    let centre = Double(correlations[chosen])
    let right = Double(correlations[min(maximumLag, chosen + 1)])
    let curvature = left - 2 * centre + right
    var fraction = curvature == 0 ? 0 : (0.5 * (left - right)) / curvature
    if !fraction.isFinite || fraction < -0.5 || fraction > 0.5 { fraction = 0 }
    let period = Double(chosen) + fraction
    let frequency = period > 0 ? analysisRate / period : 0

    return (frequency >= 55 && frequency <= 2000 ? frequency : 0, max(0, min(1, centre)))
  }
}

/// `Math.sqrt(squares / frames)`, or zero for an empty block.
func blockLevel(_ squares: Double, _ frames: Int) -> Double {
  frames > 0 ? (squares / Double(frames)).squareRoot() : 0
}

// MARK: - Line mixer

/// Six stereo channels with level, pan, mute and solo, two post-fader sends and their returns,
/// and a master. Its solo is its own, because it can see all six of its channels.
enum LineMixer {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    // Derived from the slots, as the reference derives it: stereo channels, then two stereo
    // returns.
    let channels = (inlets.count - 4) >> 1

    let mainLeft = outlets[0]
    let mainRight = outlets[1]
    let sendALeft = outlets[2]
    let sendARight = outlets[3]
    let sendBLeft = outlets[4]
    let sendBRight = outlets[5]

    // Function-major: every level, then every pan, and so on.
    let level = 0
    let pan = channels
    let mute = channels * 2
    let solo = channels * 3
    let sendA = channels * 4
    let sendB = channels * 5
    let master = channels * 6
    let returnA = master + 1
    let returnB = master + 2

    let returnASlot = channels * 2
    let returnBSlot = returnASlot + 2

    for i in 0..<frames {
      var soloed = false
      for c in 0..<channels where params[solo + c][i] >= 0.5 {
        soloed = true
        break
      }

      var outLeft = 0.0
      var outRight = 0.0
      var aLeft = 0.0
      var aRight = 0.0
      var bLeft = 0.0
      var bRight = 0.0

      for c in 0..<channels {
        if params[mute + c][i] >= 0.5 { continue }
        if soloed && !(params[solo + c][i] >= 0.5) { continue }

        let gain = Double(params[level + c][i])
        var placement = Double(params[pan + c][i])
        if placement < -1 { placement = -1 } else if placement > 1 { placement = 1 }

        let left = Double(inlets[c * 2][i]) * gain
        let right = Double(inlets[c * 2 + 1][i]) * gain
        // Balance, as the graph pans an Out: unity on both at centre.
        let placedLeft = placement <= 0 ? left : left * (1 - placement)
        let placedRight = placement >= 0 ? right : right * (1 + placement)

        outLeft += placedLeft
        outRight += placedRight

        let a = Double(params[sendA + c][i])
        aLeft += placedLeft * a
        aRight += placedRight * a
        let b = Double(params[sendB + c][i])
        bLeft += placedLeft * b
        bRight += placedRight * b
      }

      let returnGainA = Double(params[returnA][i])
      outLeft += Double(inlets[returnASlot][i]) * returnGainA
      outRight += Double(inlets[returnASlot + 1][i]) * returnGainA
      let returnGainB = Double(params[returnB][i])
      outLeft += Double(inlets[returnBSlot][i]) * returnGainB
      outRight += Double(inlets[returnBSlot + 1][i]) * returnGainB

      let fader = Double(params[master][i])
      mainLeft[i] = Float(outLeft * fader)
      mainRight[i] = Float(outRight * fader)
      // Sends are pre-master.
      sendALeft[i] = Float(aLeft)
      sendARight[i] = Float(aRight)
      sendBLeft[i] = Float(bLeft)
      sendBRight[i] = Float(bRight)
    }
  }
}

// MARK: - Combinator

/// Four rotaries and four buttons. What they move is applied when the patch compiles; here they
/// only leave as CV, a rotary as 0..1 and a button as a gate.
enum Combinator {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    // Half the outlets are rotaries and half are buttons, in that order.
    let rotaries = outlets.count / 2
    for control in 0..<rotaries {
      let rotary = outlets[control]
      let knob = params[control]
      for i in 0..<frames {
        var value = Double(knob[i]) / 127
        if value < 0 { value = 0 } else if value > 1 { value = 1 }
        rotary[i] = Float(value)
      }

      let gate = outlets[rotaries + control]
      let button = params[rotaries + control]
      for i in 0..<frames { gate[i] = button[i] >= 0.5 ? 1 : 0 }
    }
  }
}

// MARK: - Definitions

extension RackModules {
  static let controlDefs: [ModuleDef] = [follower, quantizer, meter, tuner, lineMixer, combi]

  static func makeControl(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo)
    -> ControlProcessor?
  {
    switch type {
    case "follower": .follower(Follower(sampleRate: sampleRate))
    case "quantizer": .quantizer(Quantizer(sampleRate: sampleRate))
    case "meter": .meter(VUMeter(sampleRate: sampleRate))
    case "tuner": .tuner(Tuner(sampleRate: sampleRate))
    case "line-mixer": .lineMixer
    case "combi": .combi
    default: nil
    }
  }

  static let follower = ModuleDef(
    type: "follower", name: "Follower", inlets: [Port("in", "In")],
    outlets: [Port("env", "Env"), Port("gate", "Gate")],
    params: [
      ParamDef("attack", "Attack", min: 0.0005, max: 1, default: 0.005),
      ParamDef("release", "Release", min: 0.0005, max: 2, default: 0.15),
      ParamDef("gain", "Gain", min: 0, max: 8, default: 1),
      ParamDef("threshold", "Thresh", min: 0, max: 2, default: 0.2),
    ])

  static let quantizer = ModuleDef(
    type: "quantizer", name: "Quantizer", inlets: [Port("in", "In")],
    outlets: [Port("out", "Out"), Port("trig", "Trig")],
    params: [
      ParamDef("scale", "Scale", min: 0, max: 5, default: 2, stepped: true),
      ParamDef("root", "Root", min: 0, max: 11, default: 0, stepped: true),
    ])

  static let meter: ModuleDef = {
    var def = ModuleDef(
      type: "meter", name: "VU Meter", inlets: [Port("in", "In")],
      outlets: [Port("thru", "Thru"), Port("env", "Env")],
      params: [
        ParamDef("gain", "Sensitivity", min: 0.25, max: 4, default: 1),
        ParamDef("release", "Release", min: 0.05, max: 1.5, default: 0.3),
        ParamDef("mode", "Display", min: 0, max: 2, default: 0, stepped: true),
      ])
    def.poly = false
    return def
  }()

  static let tuner: ModuleDef = {
    var def = ModuleDef(
      type: "tuner", name: "Chromatic Tuner", inlets: [Port("in", "In")], outlets: [Port("thru", "Thru")],
      params: [
        ParamDef("reference", "A4", min: 400, max: 480, default: 440),
        ParamDef("mute", "Mute", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.poly = false
    return def
  }()

  /// Params are function-major, a row of each control across the six channels, and the processor
  /// derives every offset from that order.
  static let lineMixer: ModuleDef = {
    let channels = 1...6
    func row(
      _ id: String, _ name: String, min: Double, max: Double, default value: Double, stepped: Bool = false
    )
      -> [ParamDef]
    {
      channels.map {
        ParamDef("\(id)\($0)", "\(name) \($0)", min: min, max: max, default: value, stepped: stepped)
      }
    }
    var def = ModuleDef(
      type: "line-mixer", name: "Line Mixer",
      inlets: channels.map { Port("in\($0)", "In \($0)", stereo: true) } + [
        Port("returnA", "Return A", stereo: true), Port("returnB", "Return B", stereo: true),
      ],
      outlets: [
        Port("out", "Main", stereo: true), Port("sendA", "Send A", stereo: true),
        Port("sendB", "Send B", stereo: true),
      ],
      params: row("level", "Level", min: 0, max: 1, default: 0.7)
        + row("pan", "Pan", min: -1, max: 1, default: 0)
        + row("mute", "Mute", min: 0, max: 1, default: 0, stepped: true)
        + row("solo", "Solo", min: 0, max: 1, default: 0, stepped: true)
        + row("sendA", "Send A", min: 0, max: 1, default: 0)
        + row("sendB", "Send B", min: 0, max: 1, default: 0) + [
          ParamDef("master", "Master", min: 0, max: 1.5, default: 1),
          ParamDef("returnLevelA", "Return A", min: 0, max: 1.5, default: 1),
          ParamDef("returnLevelB", "Return B", min: 0, max: 1.5, default: 1),
        ])
    def.poly = false
    return def
  }()

  /// Rotaries run 0..127, Reason's range, and rest at the reference's `Math.round(127 / 2)`;
  /// outlets are the rotaries then the buttons, as the params are.
  static let combi: ModuleDef = {
    let controls = 1...4
    var def = ModuleDef(
      type: "combi", name: "Combinator", inlets: [],
      outlets: controls.map { Port("rotary\($0)", "Rotary \($0)") }
        + controls.map { Port("button\($0)", "Button \($0)") },
      params: controls.map { ParamDef("rotary\($0)", "Rotary \($0)", min: 0, max: 127, default: 64) }
        + controls.map { ParamDef("button\($0)", "Button \($0)", min: 0, max: 1, default: 0, stepped: true) })
    def.poly = false
    return def
  }()
}
