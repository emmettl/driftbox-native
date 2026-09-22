// The rack's document and its vocabulary. A port of the patch half of
// `driftbox/packages/rack/src/types.ts`: a patch is modules and the cables between them, and a
// module is a type, an id and its knob positions. Everything here is plain data, because a patch
// arrives from outside the program — a file, a link — and has to survive being wrong.

/// A module in a patch: what it is, which one it is, and where its knobs are.
public struct PatchModule: Equatable, Sendable {
  public var id: String
  /// Stable forever: this is what a patch stores, and what the registry is looked up by.
  public var type: String
  /// The module's own version when the patch was saved; nil means current.
  public var version: Int?
  public var params: [String: Double]
  /// Per inlet, a gain between -1 and 1 applied before the module reads it. Unity is no trim.
  public var inputTrims: [String: Double]
  public var bypassed: Bool
  /// Bulk data the patch carries for the module — a pattern, a table — by slot.
  public var data: [String: [Double]]

  public init(
    id: String, type: String, version: Int? = nil, params: [String: Double] = [:],
    inputTrims: [String: Double] = [:], bypassed: Bool = false, data: [String: [Double]] = [:]
  ) {
    self.id = id
    self.type = type
    self.version = version
    self.params = params
    self.inputTrims = inputTrims
    self.bypassed = bypassed
    self.data = data
  }
}

/// One end of a cable: a module, and one of its ports.
public struct PortReference: Equatable, Hashable, Sendable {
  public var module: String
  public var port: String

  public init(_ module: String, _ port: String) {
    self.module = module
    self.port = port
  }
}

public struct PatchCable: Equatable, Sendable {
  public var from: PortReference
  public var to: PortReference

  public init(from: PortReference, to: PortReference) {
    self.from = from
    self.to = to
  }
}

/// A Combinator routing: one knob (`from`) driving another (`to`) across a range.
public struct ModRoute: Equatable, Sendable {
  public var from: PortReference
  public var to: PortReference
  public var min: Double?
  public var max: Double?

  public init(from: PortReference, to: PortReference, min: Double? = nil, max: Double? = nil) {
    self.from = from
    self.to = to
    self.min = min
    self.max = max
  }
}

public struct Patch: Equatable, Sendable {
  public var modules: [PatchModule]
  public var cables: [PatchCable]
  /// How many notes the patch plays at once, 1 to 8. Nil is one.
  public var voices: Double?
  public var tempo: Double?
  public var modulation: [ModRoute]

  public init(
    modules: [PatchModule], cables: [PatchCable], voices: Double? = nil, tempo: Double? = nil,
    modulation: [ModRoute] = []
  ) {
    self.modules = modules
    self.cables = cables
    self.voices = voices
    self.tempo = tempo
    self.modulation = modulation
  }
}

// MARK: - What a module is

/// A jack. A stereo port owns two consecutive buffers; nothing else about the signal changes.
public struct Port: Sendable {
  public var id: String
  public var name: String
  public var stereo: Bool
  /// Older ids this port answers to, with the channel an old mono cable meant when the port
  /// has since become stereo.
  public var aliases: [(id: String, channel: Int?)]

  public init(_ id: String, _ name: String, stereo: Bool = false, aliases: [(id: String, channel: Int?)] = [])
  {
    self.id = id
    self.name = name
    self.stereo = stereo
    self.aliases = aliases
  }

  var channels: Int { stereo ? 2 : 1 }
}

public struct ParamDef: Sendable {
  public var id: String
  public var name: String
  public var min: Double
  public var max: Double
  public var defaultValue: Double
  /// A selector rather than a knob: it jumps where a knob ramps, because two thirds of the way
  /// between saw and pulse is not a sound.
  public var stepped: Bool
  /// Written by the host, never by a knob — a MIDI module's note. A Combinator routing onto one
  /// is ignored, since it would be a second writer on it.
  public var hidden: Bool

  public init(
    _ id: String, _ name: String, min: Double, max: Double, default value: Double, stepped: Bool = false,
    hidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.min = min
    self.max = max
    defaultValue = value
    self.stepped = stepped
    self.hidden = hidden
  }
}

/// Everything the compiler needs to know about a module type. The processor itself is made by
/// `RackModules.make`, by type.
public struct ModuleDef: Sendable {
  public var type: String
  public var version: Int
  public var name: String
  public var inlets: [Port]
  public var outlets: [Port]
  public var params: [ParamDef]
  /// Its first outlet sums into the rack's output.
  public var terminal = false
  public var terminalPan: String?
  public var terminalMute: String?
  public var terminalSolo: String?
  /// False for a module that must run once whatever the voice count: a delay run per voice is
  /// eight delays.
  public var poly = true
  /// Child output voices per input voice.
  public var voiceExpansion: Int?
  public var voiceCollector = false
  /// The names of the bulk data slots it reads, in the order `ProcessContext.data` holds them.
  public var dataSlots: [String] = []
  /// Doubles of scratch every voice of one module shares.
  public var sharedDoubles = 0

  public init(
    type: String, version: Int = 1, name: String, inlets: [Port], outlets: [Port], params: [ParamDef]
  ) {
    self.type = type
    self.version = version
    self.name = name
    self.inlets = inlets
    self.outlets = outlets
    self.params = params
  }
}

/// Where the transport is, once per block, for the modules that follow it.
public struct Transport: Sendable {
  public var tempo: Double
  public var running: Bool
  /// Beats since the transport started, at the top of this block.
  public var beat: Double
  public var beatsPerBlock: Double
  public var shuffle: Double

  @_noAllocation
  public init(tempo: Double, running: Bool, beat: Double, beatsPerBlock: Double, shuffle: Double) {
    self.tempo = tempo
    self.running = running
    self.beat = beat
    self.beatsPerBlock = beatsPerBlock
    self.shuffle = shuffle
  }
}
