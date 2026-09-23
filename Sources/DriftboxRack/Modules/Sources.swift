import DriftboxDSP

// The sources: the wavetable oscillator, the Voice, the sampler, the multisample instrument, the
// audio input and the audio track, each a port of its file in `driftbox/packages/rack/src/modules`.
// The family's processors are one enum here, behind one case of `RackProcessor`, so its modules
// can be added without touching anyone else's.

public enum SourceProcessor {
  case wavetable(WavetableModule)
  case voice(VoiceModule)
  case sampler(Sampler)
  case multisampler(Multisampler)
  case audioInput
  case audioTrack(AudioTrack)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .wavetable(var module):
      module.process(inlets, outlets, params, context)
      self = .wavetable(module)
    case .voice(var module):
      module.process(inlets, outlets, params, context)
      self = .voice(module)
    case .sampler(var module):
      module.process(inlets, outlets, params, context)
      self = .sampler(module)
    case .multisampler(var module):
      module.process(inlets, outlets, params, context)
      self = .multisampler(module)
    case .audioInput: AudioInput.process(inlets, outlets, params, context)
    case .audioTrack(var module):
      module.process(inlets, outlets, params, context)
      self = .audioTrack(module)
    }
  }

  func meter() -> MeterReading? { nil }

  /// Nothing to give back: the wavetable bank is shared for the life of the program, and the
  /// recordings belong to the graph.
  mutating func release() {}
}

/// The host's live input, bus 4, as an ordinary outlet: the left channel or the right, a mono
/// stream answering for either.
enum AudioInput {
  @_noAllocation
  static func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let out = outlets[0]
    let level = params[0]
    let channel = params[1]
    // Buses 0 to 3 belong to the retained 808, 909 and two 303s.
    let left = context.host.buffer(bus: 4, channel: 0)
    let right = context.host.buffer(bus: 4, channel: 1) ?? left
    for i in 0..<frames {
      let source = channel[i] >= 0.5 ? right : left
      var value = 0.0
      if let source { value = Double(source[i]) }
      out[i] = Float(value * Double(level[i]))
    }
  }
}

extension RackModules {
  static let sourceDefs: [ModuleDef] = [wavetable, voice, sampler, multisampler, audioInput, audioTrack]

  static func makeSource(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo) -> SourceProcessor?
  {
    switch type {
    case "wavetable": .wavetable(WavetableModule(sampleRate: sampleRate, bank: WavetableBank.shared))
    case "voice": .voice(VoiceModule(sampleRate: sampleRate))
    case "sampler": .sampler(Sampler(sampleRate: sampleRate))
    case "multisampler": .multisampler(Multisampler(sampleRate: sampleRate))
    case "audio-input": .audioInput
    case "audio-track": .audioTrack(AudioTrack(sampleRate: sampleRate))
    default: nil
    }
  }

  static let wavetable = ModuleDef(
    type: "wavetable", name: "Wavetable",
    inlets: [Port("pitch", "V/Oct"), Port("fm", "FM"), Port("pm", "PM"), Port("pos", "Position")],
    outlets: [Port("out", "Out")],
    params: [
      ParamDef("tune", "Tune", min: -24, max: 24, default: 0),
      ParamDef("position", "Position", min: 0, max: 1, default: 0.5),
      ParamDef("index", "Index", min: 0, max: 4, default: 0),
    ])

  static let voice = ModuleDef(
    type: "voice", name: "Voice",
    inlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("cutoff", "Cutoff")],
    outlets: [Port("out", "Out"), Port("env", "Env")],
    params: [
      ParamDef("tune", "Tune", min: -24, max: 24, default: 0),
      ParamDef("shapeA", "Osc 1", min: 0, max: 2, default: 0, stepped: true),
      ParamDef("shapeB", "Osc 2", min: 0, max: 2, default: 0, stepped: true),
      ParamDef("detune", "Detune", min: -50, max: 50, default: 7),
      ParamDef("mix", "Mix", min: 0, max: 1, default: 0.5),
      ParamDef("width", "Width", min: 0.05, max: 0.95, default: 0.5),
      ParamDef("cutoff", "Cutoff", min: 20, max: 18000, default: 1200),
      ParamDef("resonance", "Res", min: 0, max: 1, default: 0.2),
      ParamDef("envAmount", "Env", min: 0, max: 6, default: 2),
      ParamDef("keyTrack", "Key", min: 0, max: 1, default: 0.35),
      ParamDef("attack", "Attack", min: 0, max: 4, default: 0.005),
      ParamDef("decay", "Decay", min: 0.001, max: 8, default: 0.4),
      ParamDef("sustain", "Sustain", min: 0, max: 1, default: 0.7),
      ParamDef("release", "Release", min: 0.001, max: 8, default: 0.25),
      ParamDef("fDecay", "F.Decay", min: 0.001, max: 8, default: 0.35),
      ParamDef("glide", "Glide", min: 0, max: 1, default: 0),
      ParamDef("level", "Level", min: 0, max: 1, default: 0.7),
    ])

  static let sampler: ModuleDef = {
    var def = ModuleDef(
      type: "sampler", name: "Sampler",
      inlets: [Port("trig", "Trig"), Port("slice", "Slice"), Port("pitch", "V/Oct")],
      outlets: [Port("out", "Out"), Port("eoc", "EOC")],
      params: [
        ParamDef("slices", "Slices", min: 1, max: 32, default: 16, stepped: true),
        ParamDef("slice", "Slice", min: 0, max: 31, default: 0, stepped: true),
        ParamDef("start", "Start", min: 0, max: 1, default: 0),
        ParamDef("loop", "Loop", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("reverse", "Rev", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.dataSlots = ["sample"]
    return def
  }()

  static let multisampler: ModuleDef = {
    var def = ModuleDef(
      type: "multisampler", name: "Multisample Instrument",
      inlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      outlets: [Port("out", "Out"), Port("env", "Env")],
      params: [
        ParamDef("tune", "Tune", min: -24, max: 24, default: 0),
        ParamDef("attack", "Attack", min: 0, max: 2, default: 0.002),
        ParamDef("release", "Release", min: 0.001, max: 8, default: 0.2),
        ParamDef("velocity", "Velocity", min: 0, max: 1, default: 1),
        ParamDef("level", "Level", min: 0, max: 1, default: 0.8),
      ])
    // The zones, then a slot for each zone's recording, in the order `Multisampler` reads them.
    var slots = ["zones"]
    for index in 0..<Multisampler.sampleSlots { slots.append("sample\(index)") }
    def.dataSlots = slots
    return def
  }()

  static let audioInput: ModuleDef = {
    var def = ModuleDef(
      type: "audio-input", name: "Audio Input", inlets: [], outlets: [Port("out", "Out")],
      params: [
        ParamDef("level", "Level", min: 0, max: 4, default: 1),
        ParamDef("channel", "Channel", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.poly = false
    return def
  }()

  static let audioTrack: ModuleDef = {
    var def = ModuleDef(
      type: "audio-track", name: "Audio Track", inlets: [], outlets: [Port("out", "Out", stereo: true)],
      params: [
        ParamDef("start", "Start", min: 0, max: 1023, default: 0, stepped: true),
        ParamDef("level", "Level", min: 0, max: 2, default: 1),
      ])
    def.poly = false
    def.dataSlots = ["left", "right", "sampleRate"]
    return def
  }()
}
