import DriftboxDSP

/// The modules this build has: their definitions, which the compiler reads, and how to make one
/// running. The ids, ports and params are the reference's exactly — a patch names them, so they
/// are the file format — in the order its defs declare them, which is the order a processor's
/// slots arrive in.
public enum RackModules {
  public static let all: [ModuleDef] =
    [out, vco, noise, vca, mixer, ladder, svf, adsr, lfo, offset, sampleHold, delay]
    + shapingDefs + spaceDefs + controlDefs + sourceDefs + sequencingDefs + playerDefs
    + filterDefs + [plugin, pluginInstrument]

  public static let registry: [String: ModuleDef] = {
    var byType: [String: ModuleDef] = [:]
    for def in all { byType[def.type] = def }
    return byType
  }()

  /// A processor for one voice of one module. `id` seeds anything random in it, so a module's
  /// second voice, `id#1`, is a different noise from its first.
  public static func make(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo = .single)
    -> RackProcessor?
  {
    switch type {
    case "out": .out
    case "vco": .vco(VCO(sampleRate: sampleRate))
    case "noise": .noise(NoiseSource(random: RackRandom(seed: id)))
    case "vca": .vca
    case "mixer": .mixer
    case "ladder": .ladder(LadderModule(filter: Ladder(sampleRate: sampleRate)))
    case "svf": .svf(SVF(sampleRate: sampleRate))
    case "adsr": .adsr(ADSR(sampleRate: sampleRate))
    case "lfo": .lfo(LFO(sampleRate: sampleRate, id: id))
    case "offset": .offset
    case "sample-hold": .sampleHold(SampleHold())
    case "delay": .delay(Delay(sampleRate: sampleRate))
    // The stereo inlet takes the first two slots.
    case "plugin": .external(ExternalProcessor(cvBase: 2))
    case "plugin-instrument": .instrument(InstrumentProcessor())
    default:
      makeShaping(type, sampleRate: sampleRate, id: id, voice: voice).map { .shaping($0) }
        ?? makeSpace(type, sampleRate: sampleRate, id: id, voice: voice).map { .space($0) }
        ?? makeControl(type, sampleRate: sampleRate, id: id, voice: voice).map { .control($0) }
        ?? makeSource(type, sampleRate: sampleRate, id: id, voice: voice).map { .sources($0) }
        ?? makeSequencing(type, sampleRate: sampleRate, id: id, voice: voice).map { .sequencing($0) }
        ?? makePlayer(type, sampleRate: sampleRate, id: id, voice: voice).map { .players($0) }
        ?? makeFilter(type, sampleRate: sampleRate, id: id, voice: voice).map { .filters($0) }
    }
  }

  static let out: ModuleDef = {
    var def = ModuleDef(
      type: "out", name: "Out", inlets: [Port("in", "In", stereo: true)],
      outlets: [Port("out", "Thru", stereo: true)],
      params: [
        ParamDef("level", "Level", min: 0, max: 1, default: 0.7),
        ParamDef("pan", "Pan", min: -1, max: 1, default: 0),
        ParamDef("mute", "Mute", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("solo", "Solo", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.terminal = true
    def.terminalPan = "pan"
    def.terminalMute = "mute"
    def.terminalSolo = "solo"
    def.poly = false
    return def
  }()

  static let vco = ModuleDef(
    type: "vco", name: "VCO", inlets: [Port("pitch", "V/Oct"), Port("fm", "FM")],
    outlets: [Port("out", "Out")],
    params: [
      ParamDef("tune", "Tune", min: -24, max: 24, default: 0),
      ParamDef("shape", "Shape", min: 0, max: 2, default: 0, stepped: true),
      ParamDef("width", "Width", min: 0.05, max: 0.95, default: 0.5),
    ])

  static let noise = ModuleDef(
    type: "noise", name: "Noise", inlets: [], outlets: [Port("white", "White"), Port("pink", "Pink")],
    params: [])

  static let vca = ModuleDef(
    type: "vca", name: "VCA", inlets: [Port("in", "In"), Port("cv", "CV")], outlets: [Port("out", "Out")],
    params: [
      ParamDef("gain", "Gain", min: 0, max: 1, default: 1),
      ParamDef("curve", "Curve", min: 0, max: 1, default: 0, stepped: true),
    ])

  static let mixer = ModuleDef(
    type: "mixer", name: "Mixer",
    inlets: (1...4).map { Port("in\($0)", "In \($0)") } + (1...4).map { Port("cv\($0)", "CV \($0)") },
    outlets: [Port("out", "Out")],
    params: (1...4).map { ParamDef("level\($0)", "Level \($0)", min: -2, max: 2, default: 1) })

  static let ladder = ModuleDef(
    type: "ladder", name: "Ladder", inlets: [Port("in", "In"), Port("cutoff", "Cutoff"), Port("res", "Res")],
    outlets: [Port("out", "Out")],
    params: [
      ParamDef("cutoff", "Cutoff", min: 20, max: 12000, default: 800),
      ParamDef("resonance", "Res", min: 0, max: 1, default: 0.4),
    ])

  static let svf = ModuleDef(
    type: "svf", name: "SVF", inlets: [Port("in", "In"), Port("cutoff", "Cutoff"), Port("res", "Res")],
    outlets: [Port("lp", "LP"), Port("hp", "HP"), Port("bp", "BP"), Port("notch", "Notch")],
    params: [
      ParamDef("cutoff", "Cutoff", min: 20, max: 18000, default: 1000),
      ParamDef("resonance", "Res", min: 0, max: 1, default: 0),
    ])

  static let adsr = ModuleDef(
    type: "adsr", name: "ADSR", inlets: [Port("gate", "Gate"), Port("trig", "Trig")],
    outlets: [Port("out", "Out")],
    params: [
      ParamDef("attack", "A", min: 0.0005, max: 10, default: 0.005),
      ParamDef("decay", "D", min: 0.0005, max: 10, default: 0.2),
      ParamDef("sustain", "S", min: 0, max: 1, default: 0.6),
      ParamDef("release", "R", min: 0.0005, max: 10, default: 0.3),
    ])

  static let lfo = ModuleDef(
    type: "lfo", name: "LFO", inlets: [Port("rate", "Rate"), Port("reset", "Reset")],
    outlets: [Port("bi", "Bi"), Port("uni", "Uni")],
    params: [
      ParamDef("rate", "Rate", min: 0.01, max: 40, default: 2),
      ParamDef("shape", "Shape", min: 0, max: 4, default: 0, stepped: true),
    ])

  static let offset = ModuleDef(
    type: "offset", name: "Offset", inlets: [Port("in", "In")], outlets: [Port("out", "Out")],
    params: [
      ParamDef("gain", "Gain", min: -2, max: 2, default: 1),
      ParamDef("offset", "Offset", min: -2, max: 2, default: 0),
    ])

  static let sampleHold = ModuleDef(
    type: "sample-hold", name: "S&H", inlets: [Port("in", "In"), Port("trig", "Trig")],
    outlets: [Port("out", "Out")],
    params: [])

  static let delay: ModuleDef = {
    var def = ModuleDef(
      type: "delay", name: "Delay", inlets: [Port("in", "In"), Port("time", "Time"), Port("fb", "FB")],
      outlets: [Port("out", "Out")],
      params: [
        ParamDef("time", "Time", min: 0.0003, max: 2, default: 0.25),
        ParamDef("feedback", "FB", min: 0, max: 0.98, default: 0.3),
      ])
    def.poly = false
    return def
  }()
}
