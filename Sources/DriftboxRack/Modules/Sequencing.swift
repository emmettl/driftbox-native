import DriftboxDSP

// Transport, clock, seq, tracker, arranger, midi and note echo: each a line-for-line port of its
// file in `driftbox/packages/rack/src/modules`, as `Basics.swift` ports the first dozen. Arithmetic
// is in doubles and stored as float32, which is what JavaScript does with a Float32Array.

public enum SequencingProcessor {
  case transport(TransportModule)
  case clock(ClockModule)
  case seq(SeqModule)
  case tracker(TrackerModule)
  case arranger(ArrangerModule)
  case midi(MidiModule)
  case noteEcho(NoteEchoModule)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .transport(var module):
      module.process(inlets, outlets, params, context)
      self = .transport(module)
    case .clock(var module):
      module.process(inlets, outlets, params, context)
      self = .clock(module)
    case .seq(var module):
      module.process(inlets, outlets, params, context)
      self = .seq(module)
    case .tracker(var module):
      module.process(inlets, outlets, params, context)
      self = .tracker(module)
    case .arranger(var module):
      module.process(inlets, outlets, params, context)
      self = .arranger(module)
    case .midi(var module):
      module.process(inlets, outlets, params, context)
      self = .midi(module)
    case .noteEcho(var module):
      module.process(inlets, outlets, params, context)
      self = .noteEcho(module)
    }
  }

  func meter() -> MeterReading? { nil }

  mutating func release() {
    switch self {
    case .tracker(let module): module.release()
    default: break
    }
  }
}

/// A trigger's length in samples, a millisecond rounded up: `Math.max(1, Math.ceil(sampleRate * 0.001))`.
private func triggerSamples(_ sampleRate: Double) -> Int { Int(max(1, jsCeil(sampleRate * 0.001))) }

/// JavaScript's `x % 1`: what is left over, with the dividend's sign.
@_noAllocation
private func remainderOfOne(_ x: Double) -> Double { x.truncatingRemainder(dividingBy: 1) }

/// Bars, beats and three divisions from the transport, the only module that reads it.
public struct TransportModule {
  let trigSamples: Int
  /// Samples left in each division's pulse: quarter, eighth, sixteenth.
  var leftQuarter = 0
  var leftEighth = 0
  var leftSixteenth = 0
  /// The last beat position seen, so a division is found by crossing rather than counting.
  var previous = -1.0
  var wasRunning = false

  init(sampleRate: Double) {
    trigSamples = triggerSamples(sampleRate)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let transport = context.transport
    let runOut = outlets[0]
    let barOut = outlets[1]
    let beatOut = outlets[2]
    let quarter = outlets[3]
    let eighth = outlets[4]
    let sixteenth = outlets[5]
    let perBar = params[0]

    let perSample = transport.beatsPerBlock / Double(frames)
    let run: Float = transport.running ? 1 : 0

    for i in 0..<frames {
      let beat = transport.beat + perSample * Double(i)
      let beatsPerBar = max(1, jsRound(Double(perBar[i])))

      if transport.running && !wasRunning {
        // Pressing play fires the downbeat.
        leftQuarter = trigSamples
        leftEighth = trigSamples
        leftSixteenth = trigSamples
      } else if previous >= 0 && transport.running {
        if jsFloor(beat) > jsFloor(previous) { leftQuarter = trigSamples }
        if jsFloor(beat * 2) > jsFloor(previous * 2) { leftEighth = trigSamples }
        if jsFloor(beat * 4) > jsFloor(previous * 4) { leftSixteenth = trigSamples }
      }
      previous = beat
      wasRunning = transport.running

      runOut[i] = run
      barOut[i] = Float(remainderOfOne(remainderOfOne(beat / beatsPerBar) + 1))
      beatOut[i] = Float(remainderOfOne(remainderOfOne(beat) + 1))

      if leftQuarter > 0 { leftQuarter -= 1 }
      if leftEighth > 0 { leftEighth -= 1 }
      if leftSixteenth > 0 { leftSixteenth -= 1 }
      quarter[i] = leftQuarter > 0 ? 1 : 0
      eighth[i] = leftEighth > 0 ? 1 : 0
      sixteenth[i] = leftSixteenth > 0 ? 1 : 0
    }
  }
}

/// A free-running clock: a gate of a set width, a millisecond trigger and a phase ramp.
public struct ClockModule {
  let sampleRate: Double
  let trigSamples: Int
  var phase = 0.0
  var lastReset = 0
  /// Armed at construction, so the clock ticks the instant it starts.
  var trigLeft: Int

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    trigSamples = triggerSamples(sampleRate)
    trigLeft = trigSamples
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let rateCv = inlets[0]
    let reset = inlets[1]
    let gateOut = outlets[0]
    let trigOut = outlets[1]
    let phaseOut = outlets[2]
    let rate = params[0]
    let width = params[1]

    for i in 0..<frames {
      let resetGate = reset[i] >= 0.5 ? 1 : 0
      if resetGate == 1 && lastReset == 0 {
        // A reset fires the beat as well as restarting it.
        phase = 0
        trigLeft = trigSamples
      }
      lastReset = resetGate

      var frequency = Double(rate[i])
      let octaves = Double(rateCv[i])
      if octaves != 0 { frequency *= exp2(octaves) }
      if frequency < 0 { frequency = 0 } else if frequency > 100 { frequency = 100 }

      phase += frequency / sampleRate
      if phase >= 1 {
        phase -= 1
        if phase >= 1 { phase = 0 }
        trigLeft = trigSamples
      }

      var pw = Double(width[i])
      if pw < 0.02 { pw = 0.02 } else if pw > 0.98 { pw = 0.98 }

      gateOut[i] = phase < pw ? 1 : 0
      if trigLeft > 0 {
        trigLeft -= 1
        trigOut[i] = 1
      } else {
        trigOut[i] = 0
      }
      phaseOut[i] = Float(phase)
    }
  }
}

/// Eight steps of pitch and an on/off each, advanced by an external clock.
public struct SeqModule {
  let sampleRate: Double
  let trigSamples: Int
  /// −1 before the first clock, so the first edge plays step 0.
  var step = -1
  var lastClock = 0
  var lastReset = 0
  var trigLeft = 0
  var pitch = 0.0
  var lastGlide = Double.nan
  var glideCoef = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    trigSamples = triggerSamples(sampleRate)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let clockIn = inlets[0]
    let resetIn = inlets[1]
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let trigOut = outlets[2]
    let length = params[0]
    let glide = params[1]

    for i in 0..<frames {
      let reset = resetIn[i] >= 0.5 ? 1 : 0
      if reset == 1 && lastReset == 0 { step = -1 }
      lastReset = reset

      var steps = truncated(length[i])
      if steps < 1 { steps = 1 } else if steps > 8 { steps = 8 }

      let clock = clockIn[i] >= 0.5 ? 1 : 0
      if clock == 1 && lastClock == 0 {
        step = step + 1 >= steps ? 0 : step + 1
        trigLeft = trigSamples
      }
      lastClock = clock

      let active = step >= 0 ? step : 0
      // params[2...9] are the eight pitches, params[10...17] the eight switches.
      let target = Double(params[2 + active][i]) / 12
      let on = step >= 0 && truncated(params[10 + active][i]) == 1

      let seconds = Double(glide[i])
      if seconds != lastGlide {
        lastGlide = seconds
        glideCoef = seconds <= 0 ? 0 : powDSP(0.01, 1 / max(1, seconds * sampleRate))
      }
      pitch = target + (pitch - target) * glideCoef

      pitchOut[i] = Float(pitch)
      gateOut[i] = on && clock == 1 ? 1 : 0
      if trigLeft > 0 && on {
        trigLeft -= 1
        trigOut[i] = 1
      } else {
        if trigLeft > 0 { trigLeft -= 1 }
        trigOut[i] = 0
      }
    }
  }
}

/// Four lanes of up to sixty-four steps in eight patterns, from data rather than knobs.
public struct TrackerModule {
  static let lanes = 4
  let trigSamples: Int
  var step = -1
  var lastClock = 0
  var lastReset = 0
  /// Per lane: the step's value as written, the CV held across rests, the trigger samples left,
  /// and whether the step is sounding.
  let raw: UnsafeMutablePointer<Double>
  let held: UnsafeMutablePointer<Double>
  let trigLeft: UnsafeMutablePointer<Int>
  let open: UnsafeMutablePointer<Bool>

  init(sampleRate: Double) {
    trigSamples = triggerSamples(sampleRate)
    raw = .allocate(capacity: Self.lanes)
    raw.initialize(repeating: 0, count: Self.lanes)
    held = .allocate(capacity: Self.lanes)
    held.initialize(repeating: 0, count: Self.lanes)
    trigLeft = .allocate(capacity: Self.lanes)
    trigLeft.initialize(repeating: 0, count: Self.lanes)
    open = .allocate(capacity: Self.lanes)
    open.initialize(repeating: false, count: Self.lanes)
  }

  func release() {
    raw.deallocate()
    held.deallocate()
    trigLeft.deallocate()
    open.deallocate()
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let clockIn = inlets[0]
    let resetIn = inlets[1]
    let patternIn = inlets[2]
    let lengthParam = params[0]
    let patternParam = params[params.count - 1]
    // Three outlets a lane, as the reference derives it; never more lanes than there is state for.
    var lanes = outlets.count / 3
    if lanes > 4 { lanes = 4 }

    for i in 0..<frames {
      let reset = resetIn[i] >= 0.5 ? 1 : 0
      if reset == 1 && lastReset == 0 { step = -1 }
      lastReset = reset

      var length = Int(jsRound(Double(lengthParam[i])))
      if length < 1 { length = 1 } else if length > 64 { length = 64 }

      var pattern = Int(jsRound(Double(patternParam[i]) + Double(patternIn[i]) * 16))
      if pattern < 0 { pattern = 0 } else if pattern > 7 { pattern = 7 }

      let clock = clockIn[i] >= 0.5 ? 1 : 0
      if clock == 1 && lastClock == 0 {
        step = step + 1 >= length ? 0 : step + 1
        for lane in 0..<lanes {
          // Read on the edge only, so editing a pattern mid-step does not retrigger it. Patterns
          // sit end to end in the lane: pattern p is `[p * length, (p + 1) * length)`.
          let values = context.data[lane]
          let offset = pattern * length + step
          var value = 0.0
          if let samples = values.samples, offset < values.count { value = Double(samples[offset]) }
          let muted = jsRound(Double(params[1 + lane][i])) == 1
          if !muted { raw[lane] = value }
          open[lane] = value != 0 && !muted
          if open[lane] {
            trigLeft[lane] = trigSamples
            held[lane] = value
          }
        }
      }
      lastClock = clock

      for lane in 0..<lanes {
        let mode = jsRound(Double(params[1 + lanes + lane][i]))
        if mode == 2 {
          // Curve: the value as written, zero included, and no gate or trigger.
          outlets[lane * 3][i] = Float(raw[lane] / 16)
          outlets[lane * 3 + 1][i] = 0
          if trigLeft[lane] > 0 { trigLeft[lane] -= 1 }
          outlets[lane * 3 + 2][i] = 0
          continue
        }
        let unit = mode == 1
        outlets[lane * 3][i] = Float(held[lane] / (unit ? 16 : 12))
        outlets[lane * 3 + 1][i] = open[lane] ? 1 : 0
        if trigLeft[lane] > 0 {
          trigLeft[lane] -= 1
          outlets[lane * 3 + 2][i] = 1
        } else {
          outlets[lane * 3 + 2][i] = 0
        }
      }
    }
  }
}

/// The song: which pattern plays, and for how many bars, clocked by the bar.
public struct ArrangerModule {
  let trigSamples: Int
  var section = 0
  var elapsed = 0
  var lastClock = 0
  var lastReset = 0
  var trigLeft = 0
  var held = 0.0

  init(sampleRate: Double) {
    // Rounded rather than rounded up, unlike the other modules' triggers: the reference's choice.
    trigSamples = Int(max(1, jsRound(sampleRate * 0.001)))
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let clockIn = inlets[0]
    let resetIn = inlets[1]
    let patternOut = outlets[0]
    let trigOut = outlets[1]
    let lengthParam = params[0]

    let patterns = context.data[0]
    let repeats = context.data[1]

    for i in 0..<frames {
      var length = Int(jsRound(Double(lengthParam[i])))
      if length < 1 { length = 1 } else if length > 16 { length = 16 }

      let reset = resetIn[i] >= 0.5 ? 1 : 0
      if reset == 1 && lastReset == 0 {
        // Back to the top of the song, at the start of its first section.
        section = 0
        elapsed = 0
        trigLeft = trigSamples
      }
      lastReset = reset

      let clock = clockIn[i] >= 0.5 ? 1 : 0
      if clock == 1 && lastClock == 0 {
        elapsed += 1
        // A double, as the reference's is: a NaN in the data never ends the section.
        var bars = 1.0
        if let samples = repeats.samples, section < repeats.count { bars = jsRound(Double(samples[section])) }
        if bars < 1 { bars = 1 }
        if Double(elapsed) > bars {
          elapsed = 1
          section = section + 1 >= length ? 0 : section + 1
          trigLeft = trigSamples
        }
      }
      lastClock = clock

      // Read every sample, so editing the section playing is heard at once.
      let at = section < length ? section : 0
      var pattern = 0.0
      if let samples = patterns.samples, at < patterns.count { pattern = jsRound(Double(samples[at])) }
      held = pattern < 0 ? 0 : pattern > 7 ? 7 : pattern

      patternOut[i] = Float(held / 16)

      if trigLeft > 0 {
        trigLeft -= 1
        trigOut[i] = 1
      } else {
        trigOut[i] = 0
      }
    }
  }
}

/// A keyboard: the host writes the note, the gate and the rest as hidden params, and this copies
/// them out, with a glide on the pitch.
public struct MidiModule {
  let sampleRate: Double
  var pitch = 0.0
  var lastGlide = Double.nan
  var glideCoef = 0.0

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let velOut = outlets[2]
    let modOut = outlets[3]
    let bendOut = outlets[4]
    let aftertouchOut = outlets[5]
    let expressionOut = outlets[6]
    let breathOut = outlets[7]
    let sustainOut = outlets[8]

    let note = params[0]
    let gate = params[1]
    let velocity = params[2]
    let mod = params[3]
    let transpose = params[4]
    let glide = params[5]
    let bend = params[7]
    let aftertouch = params[8]
    let expression = params[9]
    let breath = params[10]
    let sustain = params[11]

    for i in 0..<frames {
      let seconds = Double(glide[i])
      if seconds != lastGlide {
        lastGlide = seconds
        glideCoef = seconds <= 0 ? 0 : powDSP(0.01, 1 / max(1, seconds * sampleRate))
      }
      // MIDI 36 is C2, 0 V on every pitch inlet.
      let target = (Double(note[i]) - 36 + Double(transpose[i])) / 12
      pitch = target + (pitch - target) * glideCoef

      pitchOut[i] = Float(pitch)
      gateOut[i] = gate[i] >= 0.5 ? 1 : 0
      velOut[i] = velocity[i]
      modOut[i] = mod[i]
      bendOut[i] = bend[i]
      aftertouchOut[i] = aftertouch[i]
      expressionOut[i] = expression[i]
      breathOut[i] = breath[i]
      sustainOut[i] = sustain[i] >= 0.5 ? 1 : 0
    }
  }
}

/// Repeats a note's pitch, gate and velocity in time, with a pitch step and a velocity slope on
/// every repeat. Doubles throughout, as the reference's counters are JavaScript numbers.
public struct NoteEchoModule {
  let sampleRate: Double
  var lastGate = 0
  var rootPitch = 0.0
  var inputVelocity = 1.0
  var repeats = 0.0
  var repeatIndex = 0.0
  var interval = 1.0
  var until = -1.0
  var gateSpan = 1.0
  var pitchStep = 0.0
  var velocityStep = 1.0
  var echoPitch = 0.0
  var echoVelocity = 1.0
  var echoGateLeft = 0.0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
  }

  /// A division's length in beats: a 1/128 note through a 1/2.
  @_noAllocation
  static func beats(_ division: Int) -> Double {
    switch division {
    case 0: 1.0 / 32
    case 1: 1.0 / 16
    case 2: 1.0 / 8
    case 3: 1.0 / 4
    case 4: 1.0 / 2
    case 5: 1
    case 6: 1.5
    default: 2
    }
  }

  /// Whether a step of the echo train sounds: every one does, without a `steps` pattern.
  @_noAllocation
  static func enabled(_ step: Double, _ pattern: DataBuffer) -> Bool {
    guard let samples = pattern.samples else { return true }
    return step >= Double(pattern.count) || samples[Int(step)] >= 0.5
  }

  @_noAllocation
  mutating func trigger(
    _ pitch: Double, _ velocity: Double, _ params: Slots, _ at: Int, _ transport: Transport
  ) {
    rootPitch = pitch
    inputVelocity = velocity > 0 ? max(0, min(1, velocity)) : 1
    repeats = max(1, min(16, jsRound(Double(params[3][at]))))
    repeatIndex = 0
    pitchStep = max(-12, min(12, Double(params[4][at])))
    velocityStep = max(0.1, min(2, Double(params[5][at])))

    let sync = jsRound(Double(params[0][at])) == 1
    if sync && transport.tempo > 0 {
      let division = max(0, min(7, jsRound(Double(params[2][at]))))
      interval = max(2, jsRound(Self.beats(Int(division)) * sampleRate * 60 / transport.tempo))
    } else {
      interval = max(2, jsRound(max(1, min(1000, Double(params[1][at]))) * sampleRate / 1000))
    }
    let gate = max(0.05, min(0.95, Double(params[6][at])))
    gateSpan = max(1, min(interval - 1, jsRound(interval * gate)))
    until = interval
    echoGateLeft = 0
    echoPitch = pitch
    echoVelocity = inputVelocity
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitchIn = inlets[0]
    let gateIn = inlets[1]
    let velocityIn = inlets[2]
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let velocityOut = outlets[2]
    let dryParam = params[7]
    let steps = context.data[0]

    for i in 0..<frames {
      let gate = gateIn[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastGate == 0 {
        trigger(Double(pitchIn[i]), Double(velocityIn[i]), params, i, context.transport)
      }
      lastGate = gate

      if until == 0 && repeatIndex < repeats {
        repeatIndex += 1
        echoPitch = rootPitch + pitchStep * repeatIndex / 12
        echoVelocity = max(0, min(1, inputVelocity * (1 + (velocityStep - 1) * repeatIndex)))
        echoGateLeft = Self.enabled(repeatIndex, steps) ? gateSpan : 0
        until = repeatIndex < repeats ? interval : -1
      }

      // One low sample before a repeat, so every repeat is a real gate edge.
      let gap = until == 1 && repeatIndex < repeats
      let echoing = echoGateLeft > 0 && !gap
      let dry =
        repeatIndex == 0 && gate == 1 && jsRound(Double(dryParam[i])) == 1 && Self.enabled(0, steps) && !gap
      if echoing {
        pitchOut[i] = Float(echoPitch)
        gateOut[i] = 1
        velocityOut[i] = Float(echoVelocity)
      } else if dry {
        pitchOut[i] = pitchIn[i]
        gateOut[i] = 1
        let velocity = Double(velocityIn[i])
        velocityOut[i] = velocity > 0 ? Float(max(0, min(1, velocity))) : 1
      } else {
        pitchOut[i] = Float(rootPitch)
        gateOut[i] = 0
        velocityOut[i] = 0
      }

      if echoGateLeft > 0 { echoGateLeft -= 1 }
      if until > 0 { until -= 1 }
    }
  }
}

extension RackModules {
  static let sequencingDefs: [ModuleDef] = [
    transportDef, clockDef, seqDef, trackerDef, arrangerDef, midiDef, noteEchoDef,
  ]

  static func makeSequencing(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo)
    -> SequencingProcessor?
  {
    switch type {
    case "transport": .transport(TransportModule(sampleRate: sampleRate))
    case "clock": .clock(ClockModule(sampleRate: sampleRate))
    case "seq": .seq(SeqModule(sampleRate: sampleRate))
    case "tracker": .tracker(TrackerModule(sampleRate: sampleRate))
    case "arranger": .arranger(ArrangerModule(sampleRate: sampleRate))
    case "midi": .midi(MidiModule(sampleRate: sampleRate))
    case "note-echo": .noteEcho(NoteEchoModule(sampleRate: sampleRate))
    default: nil
    }
  }

  static let transportDef: ModuleDef = {
    var def = ModuleDef(
      type: "transport", name: "Transport", inlets: [],
      outlets: [
        Port("run", "Run"), Port("bar", "Bar"), Port("beat", "Beat"), Port("quarter", "1/4"),
        Port("eighth", "1/8"), Port("sixteenth", "1/16"),
      ],
      params: [ParamDef("beatsPerBar", "Beats", min: 1, max: 16, default: 4, stepped: true)])
    def.poly = false
    return def
  }()

  static let clockDef: ModuleDef = {
    var def = ModuleDef(
      type: "clock", name: "Clock", inlets: [Port("rate", "Rate"), Port("reset", "Reset")],
      outlets: [Port("gate", "Gate"), Port("trig", "Trig"), Port("phase", "Phase")],
      params: [
        ParamDef("rate", "Rate", min: 0.05, max: 100, default: 2),
        ParamDef("width", "Width", min: 0.02, max: 0.98, default: 0.5),
      ])
    def.poly = false
    return def
  }()

  static let seqDef: ModuleDef = {
    var def = ModuleDef(
      type: "seq", name: "Seq", inlets: [Port("clock", "Clock"), Port("reset", "Reset")],
      outlets: [Port("pitch", "Pitch"), Port("gate", "Gate"), Port("trig", "Trig")],
      params: [
        ParamDef("length", "Length", min: 1, max: 8, default: 8, stepped: true),
        ParamDef("glide", "Glide", min: 0, max: 1, default: 0),
      ]
        + (1...8).map { ParamDef("pitch\($0)", "Pitch \($0)", min: -24, max: 24, default: 0) }
        + (1...8).map { ParamDef("gate\($0)", "Gate \($0)", min: 0, max: 1, default: 1, stepped: true) })
    def.poly = false
    return def
  }()

  static let trackerDef: ModuleDef = {
    var def = ModuleDef(
      type: "tracker", name: "Tracker",
      inlets: [Port("clock", "Clock"), Port("reset", "Reset"), Port("pattern", "Pattern")],
      outlets: (1...4).flatMap {
        [Port("cv\($0)", "CV \($0)"), Port("gate\($0)", "Gate \($0)"), Port("trig\($0)", "Trig \($0)")]
      },
      params: [ParamDef("length", "Steps", min: 1, max: 64, default: 16, stepped: true)]
        + (1...4).map { ParamDef("mute\($0)", "Mute \($0)", min: 0, max: 1, default: 0, stepped: true) }
        + (1...4).map { ParamDef("unit\($0)", "Mode \($0)", min: 0, max: 2, default: 0, stepped: true) }
        + [ParamDef("pattern", "Pattern", min: 0, max: 7, default: 0, stepped: true)])
    def.poly = false
    def.dataSlots = ["lane1", "lane2", "lane3", "lane4"]
    return def
  }()

  static let arrangerDef: ModuleDef = {
    var def = ModuleDef(
      type: "arranger", name: "Arranger", inlets: [Port("clock", "Bar"), Port("reset", "Reset")],
      outlets: [Port("pattern", "Pattern"), Port("trig", "Trig")],
      params: [ParamDef("length", "Sections", min: 1, max: 16, default: 4, stepped: true)])
    def.poly = false
    def.dataSlots = ["patterns", "repeats"]
    return def
  }()

  static let midiDef = ModuleDef(
    type: "midi", version: 2, name: "MIDI", inlets: [],
    outlets: [
      Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("vel", "Vel"), Port("mod", "Mod"),
      Port("bend", "Pitch Bend"), Port("aftertouch", "Aftertouch"), Port("expression", "Expression"),
      Port("breath", "Breath"), Port("sustain", "Sustain"),
    ],
    params: [
      // Hidden in the reference: the host writes these from incoming MIDI, never a knob.
      ParamDef("note", "Note", min: 0, max: 127, default: 36, hidden: true),
      ParamDef("gate", "Gate", min: 0, max: 1, default: 0, stepped: true, hidden: true),
      ParamDef("velocity", "Velocity", min: 0, max: 1, default: 0.8, hidden: true),
      ParamDef("mod", "Mod", min: 0, max: 1, default: 0, hidden: true),
      ParamDef("transpose", "Transpose", min: -24, max: 24, default: 0),
      ParamDef("glide", "Glide", min: 0, max: 1, default: 0),
      ParamDef("channel", "Ch", min: 0, max: 16, default: 0, stepped: true),
      ParamDef("bend", "Pitch Bend", min: -1, max: 1, default: 0, hidden: true),
      ParamDef("aftertouch", "Aftertouch", min: 0, max: 1, default: 0, hidden: true),
      ParamDef("expression", "Expression", min: 0, max: 1, default: 0, hidden: true),
      ParamDef("breath", "Breath", min: 0, max: 1, default: 0, hidden: true),
      ParamDef("sustain", "Sustain", min: 0, max: 1, default: 0, stepped: true, hidden: true),
    ])

  static let noteEchoDef: ModuleDef = {
    var def = ModuleDef(
      type: "note-echo", name: "Note Echo",
      inlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      outlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      params: [
        ParamDef("sync", "Sync", min: 0, max: 1, default: 1, stepped: true),
        ParamDef("time", "Time ms", min: 1, max: 1000, default: 250),
        ParamDef("division", "Division", min: 0, max: 7, default: 3, stepped: true),
        ParamDef("repeats", "Repeats", min: 1, max: 16, default: 3, stepped: true),
        ParamDef("pitch", "Pitch", min: -12, max: 12, default: 0, stepped: true),
        ParamDef("velocity", "Velocity", min: 0.1, max: 2, default: 1),
        ParamDef("gate", "Gate", min: 0.05, max: 0.95, default: 0.5),
        ParamDef("dry", "Dry", min: 0, max: 1, default: 1, stepped: true),
      ])
    def.dataSlots = ["steps"]
    return def
  }()
}
