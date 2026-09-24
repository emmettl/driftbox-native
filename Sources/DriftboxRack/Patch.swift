// The rack's document and its vocabulary. A port of the patch half of
// `driftbox/packages/rack/src/types.ts`: a patch is modules and the cables between them, and a
// module is a type, an id and its knob positions. Everything here is plain data, because a patch
// arrives from outside the program — a file, a link — and has to survive being wrong.

/// String-keyed values that remember the order their keys arrived in, as a JavaScript object
/// does: a patch written back out lists its knobs in the order it read them, so a document
/// survives a round trip byte for byte. Written with dictionary literals, read and written by
/// key; setting nil takes a key away.
public struct KeyedList<Value: Equatable & Sendable>: Equatable, Sendable, ExpressibleByDictionaryLiteral,
  Sequence
{
  public private(set) var keys: [String] = []
  public private(set) var values: [Value] = []

  public init() {}

  public init(dictionaryLiteral elements: (String, Value)...) {
    for (key, value) in elements { self[key] = value }
  }

  public var count: Int { keys.count }
  public var isEmpty: Bool { keys.isEmpty }

  public subscript(key: String) -> Value? {
    get { keys.firstIndex(of: key).map { values[$0] } }
    set {
      if let index = keys.firstIndex(of: key) {
        if let newValue {
          values[index] = newValue
        } else {
          keys.remove(at: index)
          values.remove(at: index)
        }
      } else if let newValue {
        keys.append(key)
        values.append(newValue)
      }
    }
  }

  public func makeIterator() -> Zip2Sequence<[String], [Value]>.Iterator { zip(keys, values).makeIterator() }
}

/// A module in a patch: what it is, which one it is, and where its knobs are.
public struct PatchModule: Equatable, Sendable {
  public var id: String
  /// Stable forever: this is what a patch stores, and what the registry is looked up by.
  public var type: String
  /// The module's own version when the patch was saved; nil means current.
  public var version: Int?
  public var params: KeyedList<Double>
  /// Per inlet, a gain between -1 and 1 applied before the module reads it. Unity is no trim.
  public var inputTrims: KeyedList<Double>
  public var bypassed: Bool
  /// Bulk data the patch carries for the module — a pattern, a table — by slot.
  public var data: KeyedList<[Double]>
  /// Where it sits in the rack, for the panels; nothing in the sound reads it.
  public var position: [Double]?
  /// The plug-in a `plugin` module hosts, kept whether or not this machine has it.
  public var plugin: PluginReference?

  public init(
    id: String, type: String, version: Int? = nil, params: KeyedList<Double> = [:],
    inputTrims: KeyedList<Double> = [:], bypassed: Bool = false, data: KeyedList<[Double]> = [:],
    position: [Double]? = nil, plugin: PluginReference? = nil
  ) {
    self.id = id
    self.type = type
    self.version = version
    self.params = params
    self.inputTrims = inputTrims
    self.bypassed = bypassed
    self.data = data
    self.position = position
    self.plugin = plugin
  }
}

/// A plug-in, as a patch remembers it: which one, in its format's own terms, what it is called,
/// and its state as the plug-in last gave it. The state is the plug-in's business and opaque here,
/// so a patch opened where the plug-in is missing keeps it whole for a machine that has it.
public struct PluginReference: Equatable, Sendable {
  /// `audio-unit`, for now the only one.
  public var format: String
  /// The format's own identifier: for an Audio Unit its type, subtype and manufacturer codes,
  /// as `aufx dely appl`.
  public var id: String
  public var name: String
  public var vendor: String
  /// Base64, as the host wrote it; nil for a plug-in never asked.
  public var state: String?
  /// Which of the plug-in's own params each of the module's macros turns.
  public var controls: [PluginControl]

  public init(
    format: String, id: String, name: String, vendor: String, state: String? = nil,
    controls: [PluginControl] = []
  ) {
    self.format = format
    self.id = id
    self.name = name
    self.vendor = vendor
    self.state = state
    self.controls = controls
  }
}

/// One macro mapped onto one of a plug-in's params: by the param's key, which the format keeps
/// the same from one instance to the next, and its name as it was, for when it cannot be found.
public struct PluginControl: Equatable, Sendable {
  /// 1 to 4.
  public var macro: Int
  public var key: String
  public var name: String

  public init(macro: Int, key: String, name: String) {
    self.macro = macro
    self.key = key
    self.name = name
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

/// A recorded knob: a param's value at points in time, in frames of the transport.
public struct AutomationLane: Equatable, Sendable {
  public var target: PortReference
  public var points: [(at: Int, value: Double)]
  /// Hold each value until the next rather than ramping between them.
  public var holds: Bool

  public init(target: PortReference, points: [(at: Int, value: Double)], holds: Bool = false) {
    self.target = target
    self.points = points
    self.holds = holds
  }

  public static func == (a: AutomationLane, b: AutomationLane) -> Bool {
    a.target == b.target && a.holds == b.holds && a.points.count == b.points.count
      && zip(a.points, b.points).allSatisfy { $0.at == $1.at && $0.value == $1.value }
  }
}

public struct Patch: Equatable, Sendable {
  public var modules: [PatchModule]
  public var cables: [PatchCable]
  /// How many notes the patch plays at once, 1 to 8. Nil is one.
  public var voices: Double?
  public var tempo: Double?
  public var modulation: [ModRoute]
  public var automation: [AutomationLane]
  /// The scene it is seen with, by id.
  public var visual: String?
  /// A break loaded into it, by id, and a groovebox song beside it.
  public var breakId: String?
  public var groovebox: String?

  public init(
    modules: [PatchModule], cables: [PatchCable], voices: Double? = nil, tempo: Double? = nil,
    modulation: [ModRoute] = [], automation: [AutomationLane] = [], visual: String? = nil,
    breakId: String? = nil, groovebox: String? = nil
  ) {
    self.modules = modules
    self.cables = cables
    self.voices = voices
    self.tempo = tempo
    self.modulation = modulation
    self.automation = automation
    self.visual = visual
    self.breakId = breakId
    self.groovebox = groovebox
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
