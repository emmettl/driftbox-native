import DriftboxDocument
import DriftboxHost
import DriftboxRack
import DriftboxSeq
import Foundation
import Observation

/// A platform's plug-ins, as the rack asks for them: a unit made for a `plugin` module that names
/// one, rendering in the host. The Mac answers it with Audio Units; a platform that answers nothing
/// keeps every plug-in in the patch as it was, and silent.
@MainActor
public protocol RackPluginHosting: AnyObject {
  /// A unit of `reference`, set as its state says, at the rack's rate. Throws
  /// `RackPluginFailure.missing` when there is none on this machine.
  func make(_ reference: PluginReference, sampleRate: Double) async throws -> any RackPluginUnit
  /// The plug-ins this machine has to offer, for a menu to choose from: found when first asked,
  /// which may take a while.
  func available() async -> [RackPluginChoice]
}

extension RackPluginHosting {
  /// None to choose from: a platform whose own interface lists them, as the Mac's does, or none.
  public func available() async -> [RackPluginChoice] { [] }
}

/// A plug-in there is to choose: which, and whether it is an instrument, for a `plugin-instrument`
/// module, or an effect, for a `plugin` one.
public struct RackPluginChoice: Equatable, Sendable {
  public var reference: PluginReference
  public var instrument: Bool

  public init(reference: PluginReference, instrument: Bool) {
    self.reference = reference
    self.instrument = instrument
  }

  /// The module that hosts it.
  public var moduleType: String { instrument ? "plugin-instrument" : "plugin" }
}

/// One plug-in, made.
@MainActor
public protocol RackPluginUnit: AnyObject {
  /// What the host renders it through.
  var external: RackExternal { get }
  /// How late its output is, in seconds.
  var latency: Double { get }
  /// Its settings as the patch keeps them, as of now.
  var savedState: String? { get }
  /// Its params, by the key the patch keeps them by.
  var parameters: [String: RackPluginParameter] { get }
  /// Point macro slot `slot` (0 to 3) at the param with `key`, or at nothing: the host turns it
  /// as the macro moves.
  func map(_ slot: Int, to key: String?)
  /// Called, on the main actor, when something changes its settings: with the address of the
  /// param that moved, where the unit says.
  var onChange: ((_ moved: UInt64?) -> Void)? { get set }
  /// Let go of: its interface closed, and nothing more heard from it.
  func close()
  /// What the param with `key` says it is at `fraction` of its range, in its own words and units;
  /// nil where the unit cannot say.
  func display(_ key: String, at fraction: Double) -> String?
  /// Its own interface, in a window titled `title`, brought to the front if it is already open.
  /// Closing it says the unit has changed, so whatever was done in it is kept.
  func showInterface(title: String)
}

extension RackPluginUnit {
  public func display(_ key: String, at fraction: Double) -> String? { nil }
  /// None to show: a platform whose units have none, or show theirs another way.
  public func showInterface(title: String) {}
}

/// One of a plug-in's own params, as a macro maps onto it.
public struct RackPluginParameter: Equatable, Sendable {
  /// What the patch keeps it by, which lasts from one run of the unit to the next.
  public var key: String
  public var name: String
  /// The unit's own number for it, which it says moved.
  public var address: UInt64
  /// Where it is now, 0...1 across its range as the unit shows it.
  public var fraction: Double

  public init(key: String, name: String, address: UInt64, fraction: Double) {
    self.key = key
    self.name = name
    self.address = address
    self.fraction = fraction
  }
}

public enum RackPluginFailure: Error, Equatable {
  /// Not on this machine.
  case missing
  /// It will not play the rack's stereo at the rack's rate.
  case format
}

/// The rack as an app holds it, on every platform: the patch, what is selected, which side is
/// showing, the transport, the keys being played, and an undo history — with a real-time host
/// behind it that every edit reaches. The edits are the reference store's, one for one: a
/// structural one recompiles the patch, a knob only moves its slot.
///
/// What is a platform's comes in by the ports: `AudioRouting` for where it sounds, as the session's
/// does; `AudioCapturing` for what the Audio Input module hears; `RackPluginHosting` for the plug-ins it can make; `SampleDecoding` for the audio files it
/// can read. The app calls `tick` as often as it draws, for the meters and the song's bar.
@MainActor @Observable
public final class RackSession: MIDIListener {
  /// What the rack is playing and showing.
  public private(set) var patch: Patch
  /// The catalogue patch it came from, if it did, for the header to name.
  public private(set) var name: String
  public private(set) var selection: Set<String> = []
  /// Showing the back, where the jacks and cables are.
  public private(set) var flipped = false
  /// When the rack last turned round, which the cables swing from.
  public private(set) var flippedAt: Date?
  public private(set) var running = false
  /// The last note the keys played, for the MIDI module's panel to show.
  public private(set) var lastNote: Int?
  public private(set) var sounding: [Int] = []
  /// Cables the compiler had to delay a block to break a cycle, and ones folding stereo to mono.
  public private(set) var delayed: Set<String> = []
  public private(set) var folded: Set<String> = []
  /// What the metered modules are showing, by id, as of the last `tick`.
  public private(set) var readings: [String: MeterReading] = [:]
  /// What each sampler is playing that the patch does not carry: a file, or the patch's break.
  /// The audio itself is the host's; this is what the faces say about it.
  public private(set) var samples: [String: SampleInfo] = [:]
  /// Each Multisampler's recordings, zone by zone, and each Audio Track's file: what their faces
  /// say about audio the host holds.
  public private(set) var recordings: [String: [Recording]] = [:]
  public private(set) var tracks: [String: Recording] = [:]
  /// Modules with files being read into them.
  public private(set) var loading: Set<String> = []
  /// Why the last file could not be loaded, for the face that asked.
  public private(set) var loadFailure: (module: String, reason: String)?
  /// Each failed file load, on the main actor, including repeated or simultaneous failures.
  /// The shell can notify without consuming the error still shown on the module face.
  @ObservationIgnored public var onLoadFailure: ((String) -> Void)?
  /// The Combinator whose routing is open beside the rack. Where the window is, not what the
  /// patch is, so it is never saved.
  public private(set) var editingRoutes: String?
  /// What the controllers on the desk have been taught: kept beside the patch, never in it.
  public private(set) var ccBindings: [RackCC.Binding] = []
  /// The param waiting for a controller to be turned, if one is.
  public private(set) var ccLearning: PortReference?
  /// Where each `plugin` module's unit has got to, for its face. None for a module with no
  /// unit chosen.
  public private(set) var plugins: [String: PluginStatus] = [:]
  /// The macro waiting for a param to be moved in its unit's interface, if one is.
  public private(set) var learning: (module: String, macro: Int)?
  /// The plug-ins the platform has to offer, once `findPlugins` has asked.
  public private(set) var pluginChoices: PluginChoices = .notAsked

  public enum PluginChoices: Equatable, Sendable {
    case notAsked
    case finding
    case found([RackPluginChoice])
  }

  public enum PluginStatus: Equatable, Sendable {
    case loading
    /// Playing, and how late its output is, in seconds.
    case ready(latency: Double)
    /// Not on this machine: kept in the patch as it was, and silent.
    case missing
    case failed(String)
  }

  /// A recording, for a face: its name, how long, whether stereo, and its shape.
  public struct Recording: Equatable, Sendable {
    public var name: String
    public var seconds: Double
    public var stereo = false
    public var peaks: [Double]

    public init(name: String, seconds: Double, stereo: Bool = false, peaks: [Double]) {
      self.name = name
      self.seconds = seconds
      self.stereo = stereo
      self.peaks = peaks
    }
  }

  // MARK: History

  private struct Entry {
    var patch: Patch
    var name: String
  }
  @ObservationIgnored private var undoStack: [Entry] = []
  @ObservationIgnored private var redoStack: [Entry] = []
  /// Written with the stacks, so that what reads them is told when they change.
  public private(set) var canUndo = false
  public private(set) var canRedo = false
  public private(set) var undoTitle = "Undo"
  public private(set) var redoTitle = "Redo"
  /// The knob being turned, so one turn is one step of undo however many values it passed.
  @ObservationIgnored private var turning: String?
  public static let historyLimit = 64

  // MARK: Sound

  @ObservationIgnored public let host: RackHost
  @ObservationIgnored private let audio: (any AudioRouting)?
  @ObservationIgnored private let capture: (any AudioCapturing)?
  @ObservationIgnored private let pluginHost: (any RackPluginHosting)?
  /// Whether the platform makes plug-ins at all: where it does not, there are none to offer.
  public var hostsPlugins: Bool { pluginHost != nil }
  @ObservationIgnored private let decoder: any SampleDecoding
  /// What a module's recordings can be chosen as here, as the decoder says.
  public var readable: String { decoder.readable }
  /// A keyboard for each MIDI channel notes arrive on — the typing keys are channel 1 — so two
  /// controllers on two channels do not steal each other's voices.
  @ObservationIgnored private var keyboards: [Int: RackKeyboard] = [:]
  /// Whether anything renders the host. Until something does, nothing drains its command ring,
  /// so nothing is sent to it; whatever is there is loaded the moment something starts to.
  @ObservationIgnored public private(set) var live = false
  /// Each break rendered once, at the host's rate, off the main thread.
  @ObservationIgnored private var breaks: [String: [Float]] = [:]
  @ObservationIgnored private var rendering: [String: Task<Void, Never>] = [:]
  /// The host slots each module has audio in, so a module that goes takes its audio with it.
  @ObservationIgnored private var held: [String: Set<String>] = [:]
  /// Each `plugin` module's unit, once made, and which unit it is: a module given a different
  /// one gets a new instance, and one given the same keeps its own through any edit.
  @ObservationIgnored public private(set) var units: [String: any RackPluginUnit] = [:]
  @ObservationIgnored private var unitIds: [String: String] = [:]
  @ObservationIgnored private var making: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var finding: Task<Void, Never>?
  /// Units changed since their state was last taken into the patch.
  @ObservationIgnored private var changedUnits: Set<String> = []
  @ObservationIgnored private var pendingSave: Task<Void, Never>?
  /// Where the patch is kept between launches; nil for a rack made in a test.
  @ObservationIgnored public let memory: (any RackMemory)?
  /// Called with the patch as a document, and its name, whenever it is saved: for a platform that
  /// keeps it somewhere of its own too, as a plug-in host keeps its plug-ins' state.
  @ObservationIgnored public var onSave: ((_ document: String, _ name: String) -> Void)?
  /// Closed, and not to listen to anything again.
  @ObservationIgnored private var closed = false

  // MARK: Live input

  /// Whether the platform can listen at all: where it cannot, there is no input to choose, and the
  /// Audio Input module hears nothing.
  public var takesInput: Bool { capture != nil }
  /// The device chosen to listen to, by its id; nil for whatever the system listens to.
  public var inputDevice: String? {
    didSet {
      capture?.chosen = inputDevice
      memory?.set(inputDevice ?? "", forKey: Self.inputKey)
      nameInputDevice()
    }
  }
  /// The chosen device's name, remembered with it, for saying which device it is while it is not
  /// plugged in.
  public private(set) var inputDeviceName: String?
  /// Every device there is to listen to, kept up to date as they come and go.
  public private(set) var inputs: [AudioDevice] = []
  /// The one being heard, while the patch has an Audio Input module: the chosen one while it is
  /// there, the system's while it is not.
  public private(set) var hearing: AudioDevice?
  /// The device the system listens to.
  public private(set) var systemInput: AudioDevice?
  /// Why the Audio Input module hears nothing, while it should hear something.
  public private(set) var inputError: String?

  public static let inputKey = "rack.input"
  public static let inputNameKey = "rack.input.name"

  private func nameInputDevice() {
    guard let chosen = inputDevice else {
      guard inputDeviceName != nil else { return }
      inputDeviceName = nil
      memory?.set("", forKey: Self.inputNameKey)
      return
    }
    guard let found = inputs.first(where: { $0.id == chosen }), found.name != inputDeviceName else { return }
    inputDeviceName = found.name
    memory?.set(found.name, forKey: Self.inputNameKey)
  }

  /// Listening while the rack is sounding a patch with an Audio Input module in it, and only then:
  /// a patch without one leaves the microphone alone.
  private func settleInput() {
    guard let capture else { return }
    let wanted = live && !closed && patch.modules.contains { $0.type == "audio-input" } ? host.input : nil
    if capture.destination !== wanted { capture.destination = wanted }
  }

  /// A rack on a host of its own at `sampleRate`, playing through `audio` if there is one, and
  /// making no sound until something renders it if there is not. Not `awake`, it is not played
  /// through `audio` until `wake` is called: a rack beside the groovebox that nobody has opened
  /// yet costs nothing, where rendered it costs a phone a tenth of the audio's time, silent.
  /// `input` is what its Audio Input modules hear, where the platform can listen.
  public init(
    sampleRate: Double = 48000, audio: (any AudioRouting)? = nil, input: (any AudioCapturing)? = nil,
    plugins: (any RackPluginHosting)? = nil, decoder: any SampleDecoding = WAVDecoder(),
    memory: (any RackMemory)? = nil, awake: Bool = true
  ) {
    host = RackHost(sampleRate: sampleRate)
    self.audio = audio
    capture = input
    pluginHost = plugins
    self.decoder = decoder
    self.memory = memory
    let saved = memory?.string(forKey: Self.savedKey).flatMap(PatchCodec.decode)
    let first = PatchEntry.all.first { $0.id == Self.firstPatch }
    patch = saved ?? first?.load() ?? Patch(modules: [], cables: [])
    name = saved == nil ? first?.name ?? "Untitled" : memory?.string(forKey: Self.savedNameKey) ?? "Untitled"
    ccBindings = RackCC.load(memory)
    patch = applyModulation(patch, registry: RackModules.registry)
    if let input {
      inputDevice = memory?.string(forKey: Self.inputKey).flatMap { $0.isEmpty ? nil : $0 }
      inputDeviceName = memory?.string(forKey: Self.inputNameKey).flatMap { $0.isEmpty ? nil : $0 }
      input.chosen = inputDevice
      input.onChange = { [weak self, weak input] in
        guard let self, let input else { return }
        inputs = input.devices
        nameInputDevice()
        hearing = input.current
        systemInput = input.systemDefault
        inputError = input.error
      }
      input.onChange?()
    }
    rebuild()
    if awake { wake() }
  }

  /// Played through the audio from now on, if it was made not awake: attached, and handed the
  /// patch. Nothing once it is.
  public func wake() {
    guard let audio, !live else { return }
    audio.attach(host.renderSource)
    listen()
  }

  public static let savedKey = "rack.patch"
  public static let savedNameKey = "rack.name"
  /// A small, tempo-synced instrument that plays without a break to load.
  public static let firstPatch = "pocket-sequence"

  /// Stop sounding: the host let go of by the audio it was playing through.
  public func close() {
    allNotesOff()
    closed = true
    settleInput()
    audio?.detach(host.renderSource.context)
    for id in Array(unitIds.keys) { dropUnit(id) }
  }

  /// A state a plug-in host saved, opened as the rack's patch.
  public func restore(_ document: String, name: String?) {
    guard let patch = PatchCodec.decode(document) else { return }
    open(patch, name: name ?? "Untitled")
  }

  /// Something renders the host from now on: hand it the patch, the transport and the notes.
  public func listen() {
    guard !live else { return }
    live = true
    host.load(patch)
    sendSong()
    settleInput()
    if let loop = songLoop { host.loopSong(startBar: loop.start, bars: loop.bars) }
    host.setTransport(tempo: tempo, running: running, shuffle: swing)
  }

  /// As often as the app draws: the host's latest readings, and the bar its song is on.
  public func tick() {
    guard live else { return }
    readings = host.readings()
    let bar: Int? =
      if sentSong != nil, host.song.playing.load(ordering: .relaxed) {
        songTimeline.step(at: Double(host.song.songFrame.load(ordering: .relaxed)) / host.sampleRate)
          .map { songTimeline.bars[$0] }
      } else { nil }
    if bar != songBar { songBar = bar }
  }

  // MARK: Opening

  /// Put a different patch in the rack. Its history is the old one's, so it starts afresh.
  public func open(_ patch: Patch, name: String) {
    allNotesOff()
    if songLinked {
      onUnlinkSong?()
      songLinked = false
    }
    // The engine keeps a loop from song to song, so the old one goes with the old patch.
    if songLoop != nil {
      songLoop = nil
      if live { host.loopSong(startBar: 0, bars: 0) }
    }
    // Another patch's samples are not this one's, even under the same ids, nor its units.
    host.clearSamples()
    for id in Array(unitIds.keys) { dropUnit(id) }
    samples = [:]
    recordings = [:]
    tracks = [:]
    held = [:]
    self.patch = applyModulation(patch, registry: RackModules.registry)
    self.name = name
    selection = []
    undoStack = []
    redoStack = []
    historyChanged()
    turning = nil
    rebuild()
    if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
  }

  public func open(_ entry: PatchEntry) {
    guard let patch = entry.load() else { return }
    open(patch, name: entry.name)
  }

  // MARK: Editing

  /// A change that alters the graph: recorded, then compiled and swapped in whole.
  private func structural(_ name: String, _ change: (inout Patch) -> Void) {
    var next = patch
    change(&next)
    next = applyModulation(next, registry: RackModules.registry)
    guard next != patch else { return }
    record(name)
    patch = next
    rebuild()
  }

  private func record(_ name: String) {
    turning = nil
    undoStack.append(Entry(patch: patch, name: name))
    if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
    redoStack = []
    historyChanged()
  }

  private func historyChanged() {
    if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
    if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    let undo = undoStack.last.map { "Undo \($0.name)" } ?? "Undo"
    let redo = redoStack.last.map { "Redo \($0.name)" } ?? "Redo"
    if undoTitle != undo { undoTitle = undo }
    if redoTitle != redo { redoTitle = redo }
  }

  /// Compile what is there and hand it to the host; and work out which cables to draw as what.
  private func rebuild() {
    settleSamples()
    settlePlugins()
    // Its Combinator gone, the routing closes rather than waiting to reopen on a new one of
    // the same name.
    if let combi = editingRoutes, !patch.modules.contains(where: { $0.id == combi }) { editingRoutes = nil }
    let plan: Plan
    if live {
      host.load(patch)
      sendSong()
      plan = host.plan!
    } else {
      plan = compile(patch)
    }
    let order = Dictionary(plan.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    let types = Dictionary(patch.modules.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })
    var delayed = Set<String>()
    var folded = Set<String>()
    for cable in patch.cables {
      let key = Self.key(cable)
      if let from = order[cable.from.module], let to = order[cable.to.module], from >= to {
        delayed.insert(key)
      }
      let registry = RackModules.registry
      if let fromType = types[cable.from.module], let toType = types[cable.to.module],
        registry[fromType]?.outlets.first(where: { $0.id == cable.from.port })?.stereo == true,
        registry[toType]?.inlets.first(where: { $0.id == cable.to.port })?.stereo == false
      {
        folded.insert(key)
      }
    }
    self.delayed = delayed
    self.folded = folded
    settleInput()
    for (channel, keyboard) in keyboards where keyboard.voices != voices {
      var keyboard = keyboard
      let silenced = keyboard.setVoices(voices)
      keyboards[channel] = keyboard
      for state in silenced { play(state, channel: channel) }
    }
    save()
  }

  private func save() {
    takeUnitStates()
    let document = PatchCodec.encode(patch)
    onSave?(document, name)
    guard let memory else { return }
    memory.set(document, forKey: Self.savedKey)
    memory.set(name, forKey: Self.savedNameKey)
  }

  public static func key(_ cable: PatchCable) -> String {
    Cable.key(from: (cable.from.module, cable.from.port), to: (cable.to.module, cable.to.port))
  }

  /// A knob's value, or its default.
  public func value(_ module: PatchModule, _ param: ParamDef) -> Double {
    module.params[param.id] ?? param.defaultValue
  }

  /// Turn a knob, now. The first move of a turn is what undo goes back to; the rest join it.
  /// The routings run over the result, so a rotary turns everything it drives as it turns; a
  /// knob a routing drives, turned by hand, is taken straight back — the routing owns it, and
  /// its face says so — and that is no edit at all.
  public func turn(_ moduleId: String, _ param: String, to value: Double) {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
    var next = patch
    next.modules[at].params[param] = value
    next = applyModulation(next, registry: RackModules.registry)
    guard next != patch else { return }
    let key = "\(moduleId)/\(param)"
    if turning != key {
      let name = RackModules.registry[patch.modules[at].type]?.params.first { $0.id == param }?.name ?? param
      record("Set \(name)")
      turning = key
    }
    settle(next)
    save()
  }

  /// A knob moved from outside — an app's automation, where the rack plays inside one as an Audio
  /// Unit — heard at once and kept, but no step of undo: nobody here turned it, and a DAW playing
  /// automation back would otherwise fill the history. The routings run over it as over a turn.
  public func automate(_ moduleId: String, _ param: String, to value: Double) {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
    var next = patch
    next.modules[at].params[param] = value
    next = applyModulation(next, registry: RackModules.registry)
    guard next != patch else { return }
    settle(next)
    save()
  }

  /// Take a settled patch, and send the sound every param that differs from the one before.
  private func settle(_ next: Patch) {
    if live {
      for (before, after) in zip(patch.modules, next.modules) where before.params != after.params {
        for (param, value) in after.params where before.params[param] != value {
          host.setParam(after.id, param, value)
        }
      }
    }
    patch = next
  }

  /// An inlet's trim: the gain between -1 and 1 it is read at. Unity when it has none.
  public func trim(_ moduleId: String, _ inlet: String) -> Double {
    patch.modules.first { $0.id == moduleId }?.inputTrims[inlet] ?? 1
  }

  /// Turn an inlet's trim pot, as a knob turns: one drag is one step of undo, and the sound
  /// hears it without a rebuild — except where the pot leaves unity or comes back to it. Only
  /// a pot doing something costs the graph a buffer and a multiply, so those two moments change
  /// the plan's shape, and are one rebuild each; unity is kept as no trim at all.
  public func setTrim(_ moduleId: String, _ inlet: String, to value: Double) {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }),
      RackModules.registry[patch.modules[at].type]?.inlets.contains(where: { $0.id == inlet }) == true
    else { return }
    let next = value.isFinite ? max(-1, min(1, value)) : 1
    let current = patch.modules[at].inputTrims[inlet] ?? 1
    guard next != current else { return }
    let key = "trim:\(moduleId)/\(inlet)"
    if turning != key {
      record("Set Input Trim")
      turning = key
    }
    patch.modules[at].inputTrims[inlet] = next == 1 ? nil : next
    if (current != 1) != (next != 1) {
      rebuild()
    } else {
      if live { host.setTrim(moduleId, inlet, next) }
      save()
    }
  }

  /// Change one of a module's data slots — a lane of a pattern, a song, a scale — as a gesture
  /// does: the first change of it is what undo goes back to, and it reaches the sound on the
  /// next block without rebuilding anything, so a pattern can be edited while it plays.
  public func setData(_ moduleId: String, _ slot: String, to values: [Double], name: String = "Edit Pattern")
  {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
    guard patch.modules[at].data[slot] != values else { return }
    let key = "data:\(moduleId)/\(slot)"
    if turning != key {
      record(name)
      turning = key
    }
    patch.modules[at].data[slot] = values
    if live { host.setData(moduleId, slot, values) }
    save()
  }

  /// The turn is over: the next move of the same knob is a new step of undo.
  public func endTurn() { turning = nil }

  /// A selector's choice: one step of undo on its own.
  public func set(_ moduleId: String, _ param: String, to value: Double) {
    turn(moduleId, param, to: value)
    endTurn()
  }

  /// A module at the end of the rack, with an Out of its own when it is a source, as the
  /// reference adds one. A plug-in module can come with its `plugin` chosen, in the same step.
  @discardableResult
  public func add(_ type: String, plugin: PluginReference? = nil) -> String? {
    guard let def = RackModules.registry[type] else { return nil }
    let id = Self.freshId(patch, type)
    structural("Add \(plugin?.name ?? def.name)") { patch in
      // An instrument comes played: from the rack's MIDI module, or a new one just before it.
      if type == "plugin-instrument" {
        let keys =
          patch.modules.first { $0.type == "midi" }?.id
          ?? {
            let fresh = Self.freshId(patch, "midi")
            patch.modules.append(PatchModule(id: fresh, type: "midi"))
            return fresh
          }()
        for (from, to) in [("pitch", "pitch"), ("gate", "gate"), ("vel", "velocity")] {
          patch.cables.append(PatchCable(from: PortReference(keys, from), to: PortReference(id, to)))
        }
      }
      var module = PatchModule(id: id, type: type)
      if RackModules.pluginTypes.contains(type) { module.plugin = plugin }
      patch.modules.append(module)
      guard ModuleFace.byType[type]?.group == "Sources", def.outlets.contains(where: { $0.id == "out" })
      else { return }
      let out = Self.freshId(patch, "out")
      patch.modules.append(PatchModule(id: out, type: "out", params: ["level": 0.7]))
      patch.cables.append(PatchCable(from: PortReference(id, "out"), to: PortReference(out, "in")))
    }
    selection = [id]
    return id
  }

  /// A copy beside the original, numbered as a new one is, so anything random in it differs.
  public func duplicate(_ moduleId: String) {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
    let source = patch.modules[at]
    let id = Self.freshId(patch, source.type)
    structural("Duplicate") { patch in
      var copy = source
      copy.id = id
      patch.modules.insert(copy, at: at + 1)
    }
    selection = [id]
  }

  /// A module gone, and every cable and routing that touched it with it.
  public func remove(_ moduleId: String) {
    structural("Remove Module") { patch in
      patch.modules.removeAll { $0.id == moduleId }
      patch.cables.removeAll { $0.from.module == moduleId || $0.to.module == moduleId }
      patch.modulation.removeAll { $0.from.module == moduleId || $0.to.module == moduleId }
    }
    selection.remove(moduleId)
  }

  public func setBypassed(_ moduleId: String, _ bypassed: Bool) {
    structural(bypassed ? "Bypass" : "Unbypass") { patch in
      guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
      patch.modules[at].bypassed = bypassed
    }
  }

  /// A module moved to insertion index `index` of the rack as it is.
  public func drop(_ moduleId: String, at index: Int) {
    guard let from = patch.modules.firstIndex(where: { $0.id == moduleId }),
      let modules = RackLayout.reordered(patch.modules, from: from, to: index)
    else { return }
    structural("Move Module") { $0.modules = modules }
  }

  public func move(_ moduleId: String, by offset: Int) {
    guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
    let to = at + offset
    guard to >= 0, to < patch.modules.count else { return }
    structural("Move Module") { patch in
      let module = patch.modules.remove(at: at)
      patch.modules.insert(module, at: to)
    }
  }

  /// A cable from an outlet to an inlet. One cable per inlet: whatever was there goes.
  public func connect(_ from: PortReference, _ to: PortReference) {
    structural("Connect") { patch in
      patch.cables.removeAll { $0.to == to }
      patch.cables.append(PatchCable(from: from, to: to))
    }
  }

  public func disconnect(_ cable: PatchCable) {
    structural("Disconnect") { $0.cables.removeAll { $0 == cable } }
  }

  // MARK: Routing

  /// Open one Combinator's routing beside the rack, or close it.
  public func editRoutes(_ moduleId: String?) { editingRoutes = moduleId }

  /// The params a routing can drive: any a hand could set. The hidden ones are written by the
  /// host — the MIDI module's note — and a routing would be a second writer.
  public static func routable(_ type: String) -> [ParamDef] {
    RackModules.registry[type]?.params.filter { !$0.hidden } ?? []
  }

  /// Whether a routing drives this knob, for its face to mark it.
  public func isRouted(_ moduleId: String, _ param: String) -> Bool {
    patch.modulation.contains { $0.to.module == moduleId && $0.to.port == param }
  }

  /// Where a new routing from `combi` points: a filter's cutoff if there is one, since that is
  /// what most first routings are for, or else the first knob of the first other module.
  public func defaultTarget(_ combi: String) -> PortReference? {
    let others = patch.modules.filter { $0.id != combi }
    for wanted in ["cutoff", "freq", "gain", "level"] {
      if let module = others.first(where: { Self.routable($0.type).contains { $0.id == wanted } }) {
        return PortReference(module.id, wanted)
      }
    }
    for module in others {
      if let first = Self.routable(module.type).first { return PortReference(module.id, first.id) }
    }
    return nil
  }

  /// A routing from the Combinator's first control without one, so adding four gives four
  /// rotaries rather than four routings fighting over one. It sweeps its target end to end.
  public func addRoute(_ combi: String) {
    guard let type = patch.modules.first(where: { $0.id == combi })?.type,
      let to = defaultTarget(combi)
    else { return }
    let controls = Self.routable(type).map(\.id)
    let used = Set(patch.modulation.filter { $0.from.module == combi }.map(\.from.port))
    let free = controls.first { !used.contains($0) } ?? controls.first ?? "rotary1"
    routing("Add Routing") { $0.append(ModRoute(from: PortReference(combi, free), to: to)) }
  }

  /// Change one routing. Aimed at another knob, its range goes, since it was in the old knob's
  /// units; aimed at another module, it lands on that module's first knob.
  public func setRoute(_ index: Int, _ change: (inout ModRoute) -> Void) {
    routing("Edit Routing") { routes in
      guard routes.indices.contains(index) else { return }
      var route = routes[index]
      change(&route)
      if route.to.module != routes[index].to.module,
        let type = patch.modules.first(where: { $0.id == route.to.module })?.type,
        let first = Self.routable(type).first
      {
        route.to = PortReference(route.to.module, first.id)
      }
      if route.to != routes[index].to {
        route.min = nil
        route.max = nil
      }
      // An end that is not a number is the target's own limit, which is its absence.
      if let min = route.min, !min.isFinite { route.min = nil }
      if let max = route.max, !max.isFinite { route.max = nil }
      routes[index] = route
    }
  }

  /// One end of a routing dragged, as a knob turns: the first move of a drag is what undo goes back
  /// to, and the rest join it, until `endTurn`. An end that is not a number is the target's limit.
  public func turnRoute(_ index: Int, _ change: (inout ModRoute) -> Void) {
    guard patch.modulation.indices.contains(index) else { return }
    var next = patch
    change(&next.modulation[index])
    if let min = next.modulation[index].min, !min.isFinite { next.modulation[index].min = nil }
    if let max = next.modulation[index].max, !max.isFinite { next.modulation[index].max = nil }
    guard next.modulation != patch.modulation else { return }
    let key = "route:\(index)"
    if turning != key {
      record("Edit Routing")
      turning = key
    }
    settle(applyModulation(next, registry: RackModules.registry))
    save()
  }

  public func removeRoute(_ index: Int) {
    routing("Remove Routing") { routes in
      guard routes.indices.contains(index) else { return }
      routes.remove(at: index)
    }
  }

  /// A routing edit: the patch changes and the graph does not, so it goes the way a knob does.
  private func routing(_ name: String, _ change: (inout [ModRoute]) -> Void) {
    var next = patch
    change(&next.modulation)
    guard next.modulation != patch.modulation else { return }
    record(name)
    settle(applyModulation(next, registry: RackModules.registry))
    save()
  }

  // MARK: Controllers

  /// Arm a param: the next controller turned is what moves it.
  public func startCcLearn(_ moduleId: String, _ param: String) {
    ccLearning = PortReference(moduleId, param)
  }

  public func cancelCcLearn() { ccLearning = nil }

  /// Teach the armed param controller `cc`, on any channel. Nothing armed, nothing learnt.
  public func finishCcLearn(_ cc: Int) {
    guard let armed = ccLearning else { return }
    ccBindings = RackCC.learn(ccBindings, RackCC.Binding(cc: cc, module: armed.module, param: armed.port))
    ccLearning = nil
    RackCC.save(ccBindings, to: memory)
  }

  /// Forget what a param learnt: re-learning cannot unbind, so a mistake needs a way out.
  public func clearCcBinding(_ moduleId: String, _ param: String) {
    ccBindings = RackCC.forget(ccBindings, module: moduleId, param: param)
    RackCC.save(ccBindings, to: memory)
  }

  /// A controller moved: teach it the armed param, or move what it was taught — as a hand
  /// would, so the knob on the face turns and a rotary's routings follow.
  private func control(_ cc: Int, _ raw: Int, channel: Int) {
    if ccLearning != nil {
      finishCcLearn(cc)
      return
    }
    for binding in RackCC.targets(ccBindings, cc: cc, channel: channel) {
      // A binding for a module this patch does not have is kept: its patch may open again.
      guard let module = patch.modules.first(where: { $0.id == binding.module }),
        let param = Self.routable(module.type).first(where: { $0.id == binding.param })
      else { continue }
      turn(binding.module, binding.param, to: RackCC.value(raw, param))
    }
  }

  // MARK: Selection and sides

  public func select(_ moduleId: String?, adding: Bool = false) {
    guard let moduleId else {
      selection = []
      return
    }
    if adding {
      if selection.contains(moduleId) { selection.remove(moduleId) } else { selection.insert(moduleId) }
    } else {
      selection = [moduleId]
    }
  }

  public func flip() {
    flipped.toggle()
    flippedAt = Date()
  }

  // MARK: Undo

  public func undo() {
    guard let entry = undoStack.popLast() else { return }
    redoStack.append(Entry(patch: patch, name: entry.name))
    historyChanged()
    restore(entry.patch)
  }

  public func redo() {
    guard let entry = redoStack.popLast() else { return }
    undoStack.append(Entry(patch: patch, name: entry.name))
    historyChanged()
    restore(entry.patch)
  }

  private func restore(_ patch: Patch) {
    turning = nil
    // The song's history is the groovebox's, so going back in the rack's keeps the song as it is
    // now rather than as it was when the rack last changed.
    var patch = patch
    patch.groovebox = self.patch.groovebox
    self.patch = patch
    selection = selection.filter { id in patch.modules.contains { $0.id == id } }
    rebuild()
  }

  // MARK: Plug-ins

  /// Give a `plugin` module a unit: a structural edit, undone like any other.
  public func choosePlugin(_ moduleId: String, _ reference: PluginReference) {
    structural("Choose \(reference.name)") { patch in
      guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
      patch.modules[at].plugin = reference
    }
  }

  /// Units for the `plugin` modules that name one, made as they appear; and let go of as their
  /// modules go or are given another. A unit's own settings are its to undo, so undoing in the
  /// rack changes which unit a module has, never how it is set.
  private func settlePlugins() {
    var wanted: [String: PluginReference] = [:]
    for module in patch.modules where RackModules.pluginTypes.contains(module.type) {
      if let plugin = module.plugin { wanted[module.id] = plugin }
    }
    for id in Array(unitIds.keys) where wanted[id]?.id != unitIds[id] { dropUnit(id) }
    for id in plugins.keys where wanted[id] == nil { plugins[id] = nil }
    for (id, reference) in wanted where unitIds[id] == nil { makeUnit(id, reference) }
    // Undone or redone, a module's macros may point elsewhere.
    for id in units.keys { applyMacros(id) }
  }

  private func makeUnit(_ id: String, _ reference: PluginReference) {
    unitIds[id] = reference.id
    guard let pluginHost else {
      plugins[id] = .missing
      return
    }
    plugins[id] = .loading
    let rate = host.sampleRate
    making[id] = Task { [weak self] in
      let made: Result<any RackPluginUnit, Error>
      do {
        made = .success(try await pluginHost.make(reference, sampleRate: rate))
      } catch {
        made = .failure(error)
      }
      guard let self, !Task.isCancelled, unitIds[id] == reference.id else {
        if case .success(let unit) = made { unit.close() }
        return
      }
      making[id] = nil
      switch made {
      case .success(let unit):
        units[id] = unit
        applyMacros(id)
        host.setExternal(id, unit.external)
        plugins[id] = .ready(latency: unit.latency)
        unit.onChange = { [weak self] moved in
          self?.unitChanged(id)
          if let moved { self?.learned(id, moved) }
        }
      case .failure(RackPluginFailure.missing):
        plugins[id] = .missing
      case .failure(RackPluginFailure.format):
        plugins[id] = .failed("It will not play in stereo at \(Int(rate)) Hz")
      case .failure(let error):
        plugins[id] = .failed("\(error)")
      }
    }
  }

  /// A unit let go of: silent in the host at once, its state taken first.
  private func dropUnit(_ id: String) {
    making.removeValue(forKey: id)?.cancel()
    host.setExternal(id, nil)
    units[id]?.onChange = nil
    units[id]?.close()
    units[id] = nil
    unitIds[id] = nil
    changedUnits.remove(id)
    plugins[id] = nil
    if learning?.module == id { learning = nil }
  }

  /// A unit's state is out of date in the patch: saved once things have been still for a moment.
  public func unitChanged(_ id: String) {
    changedUnits.insert(id)
    if let unit = units[id], plugins[id] != .ready(latency: unit.latency) {
      plugins[id] = .ready(latency: unit.latency)
    }
    pendingSave?.cancel()
    pendingSave = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.save()
    }
  }

  /// The changed units' states into the patch, where the next save finds them. Not an edit: a
  /// unit's settings are its own, and the patch only keeps them.
  private func takeUnitStates() {
    guard !changedUnits.isEmpty else { return }
    for id in changedUnits {
      guard let unit = units[id], let at = patch.modules.firstIndex(where: { $0.id == id }),
        patch.modules[at].plugin != nil
      else { continue }
      patch.modules[at].plugin?.state = unit.savedState
    }
    changedUnits = []
  }

  // MARK: Macros

  /// Map macro `macro` (1 to 4) of a plug-in module onto one of its unit's params, by its key, or
  /// unmap it (nil). One step of undo; the knob moves to where the param already is, so nothing
  /// jumps.
  public func mapMacro(_ moduleId: String, _ macro: Int, to key: String?) {
    guard (1...4).contains(macro), let at = patch.modules.firstIndex(where: { $0.id == moduleId }),
      patch.modules[at].plugin != nil
    else { return }
    var next = patch
    var controls = next.modules[at].plugin?.controls.filter { $0.macro != macro } ?? []
    if let key {
      guard let parameter = units[moduleId]?.parameters[key] else { return }
      controls.append(PluginControl(macro: macro, key: key, name: parameter.name))
      controls.sort { $0.macro < $1.macro }
      next.modules[at].params["macro\(macro)"] = parameter.fraction
    }
    next.modules[at].plugin?.controls = controls
    guard next != patch else { return }
    record(key == nil ? "Unmap Macro \(macro)" : "Map Macro \(macro)")
    settle(next)
    applyMacros(moduleId)
    save()
  }

  /// Map the next param moved in the unit's own interface onto macro `macro`. Opening the
  /// interface is the app's.
  public func learnMacro(_ moduleId: String, _ macro: Int) { learning = (moduleId, macro) }

  /// A plug-in module's unit's own interface, titled for the plug-in and the module, as the Mac's
  /// is.
  public func showInterface(_ moduleId: String) {
    guard let unit = units[moduleId],
      let reference = patch.modules.first(where: { $0.id == moduleId })?.plugin
    else { return }
    unit.showInterface(title: "\(reference.name) — \(moduleId)")
  }

  public func cancelLearning() { learning = nil }

  /// A param moved in a unit, while one of its module's macros is waiting for one. The params its
  /// other macros already turn are not learnt: they move when those macros do.
  private func learned(_ moduleId: String, _ address: UInt64) {
    guard let learning, learning.module == moduleId, let unit = units[moduleId],
      let parameter = unit.parameters.values.first(where: { $0.address == address }),
      let module = patch.modules.first(where: { $0.id == moduleId })
    else { return }
    let others = (module.plugin?.controls ?? []).filter { $0.macro != learning.macro }.map(\.key)
    guard !others.contains(parameter.key) else { return }
    self.learning = nil
    mapMacro(moduleId, learning.macro, to: parameter.key)
  }

  /// The param each of a unit's macros turns, found by key in the unit, into the host's mapping.
  private func applyMacros(_ moduleId: String) {
    guard let unit = units[moduleId],
      let controls = patch.modules.first(where: { $0.id == moduleId })?.plugin?.controls
    else { return }
    let parameters = unit.parameters
    for macro in 1...4 {
      let key = controls.first { $0.macro == macro }?.key
      unit.map(macro - 1, to: key.flatMap { parameters[$0] }?.key)
    }
  }

  /// What macro `macro` of a module turns: the param, when its unit has it.
  public func macroParameter(_ moduleId: String, _ macro: Int) -> (
    control: PluginControl, parameter: RackPluginParameter?
  )? {
    guard
      let control = patch.modules.first(where: { $0.id == moduleId })?.plugin?.controls
        .first(where: { $0.macro == macro })
    else { return nil }
    return (control, units[moduleId]?.parameters[control.key])
  }

  /// Once every unit being made has arrived.
  public func pluginsReady() async {
    while let task = making.values.first { await task.value }
  }

  /// Ask the platform what plug-ins it has to offer, once: `pluginChoices` says when it knows.
  public func findPlugins() {
    guard pluginChoices == .notAsked else { return }
    guard let pluginHost else {
      pluginChoices = .found([])
      return
    }
    pluginChoices = .finding
    finding = Task { [weak self] in
      let found = await pluginHost.available()
      self?.pluginChoices = .found(found)
      self?.finding = nil
    }
  }

  /// Once the plug-ins being found are.
  public func pluginsFound() async { await finding?.value }

  // MARK: Samples

  /// Samplers gone from the patch lose their audio; samplers with none get the patch's break,
  /// as the reference gives every one of them on Start.
  private func settleSamples() {
    let present = Set(patch.modules.map(\.id))
    for (id, slots) in held where !present.contains(id) {
      for slot in slots { host.setSample(id, slot, nil) }
      held[id] = nil
      samples[id] = nil
      recordings[id] = nil
      tracks[id] = nil
    }
    let samplers = Set(patch.modules.filter { $0.type == "sampler" }.map(\.id))
    guard let id = patch.breakId, let entry = RackBreak.named(id) else { return }
    guard let audio = breaks[id] else {
      guard rendering[id] == nil, samplers.contains(where: { samples[$0] == nil }) else { return }
      let rate = host.sampleRate
      rendering[id] = Task { [weak self] in
        let audio = await Task.detached(priority: .userInitiated) { entry.render(sampleRate: rate) }.value
        guard let self else { return }
        breaks[id] = audio
        rendering[id] = nil
        settleSamples()
      }
      return
    }
    for module in samplers where samples[module] == nil {
      hold(module, "sample", audio)
      samples[module] = SampleInfo(
        name: entry.name, bars: 1, seconds: 240 / entry.tempo, peaks: SampleMath.waveformPeaks(audio),
        source: .break)
    }
  }

  /// Once every break being rendered has arrived.
  public func breaksReady() async {
    while let task = rendering.values.first { await task.value }
  }

  /// Read an audio file into a sampler: at the rack's rate, mono, its loudest sample 0.9. The
  /// rack's tempo becomes the one at which the file is a whole number of bars — whichever of one,
  /// two, four or eight is nearest the tempo it had — and the transport starts, as the reference
  /// does, so the loop is heard in time at once.
  public func load(_ url: URL, into moduleId: String) async {
    loading.insert(moduleId)
    loadFailure = nil
    defer { loading.remove(moduleId) }
    switch await decode([url]) {
    case .failure(let error):
      loadFailed(error, into: moduleId)
    case .success(let decoded):
      let audio = SampleMath.normalise(SampleMath.toMono(decoded[0]))
      guard patch.modules.contains(where: { $0.id == moduleId }), audio.count > 1 else { return }
      let rate = host.sampleRate
      let seconds = Double(audio.count) / rate
      let bars = SampleMath.guessBars(seconds, tempo: tempo)
      hold(moduleId, "sample", audio)
      samples[moduleId] = SampleInfo(
        name: SampleMath.name(url.lastPathComponent), bars: bars, seconds: seconds,
        peaks: SampleMath.waveformPeaks(audio), source: .file)
      setTempo(SampleMath.tempoForBars(seconds, bars))
      endTurn()
      if !running { toggleRunning() }
    }
  }

  /// Audio in one of a module's slots, or none, remembered as the module's.
  private func hold(_ module: String, _ slot: String, _ audio: [Float]?) {
    host.setSample(module, slot, audio)
    if audio == nil { held[module]?.remove(slot) } else { held[module, default: []].insert(slot) }
  }

  /// Files read at the rack's rate, every channel, off the main thread.
  private func decode(_ urls: [URL]) async -> Result<[[[Float]]], Error> {
    let rate = host.sampleRate
    let decoder = decoder
    return await Task.detached(priority: .userInitiated) {
      Result {
        try urls.map { url in
          do { return try decoder.decode(url, sampleRate: rate) } catch {
            throw SampleFileFailure(name: url.lastPathComponent, reason: FailureMessage.describe(error))
          }
        }
      }
    }.value
  }

  private func loadFailed(_ error: any Error, into module: String) {
    let reason = FailureMessage.describe(error)
    loadFailure = (module, reason)
    onLoadFailure?(reason)
  }

  /// A set of recordings into a Multisampler, mapped by their names — Piano_C3_pp maps itself —
  /// each mono and loud. The map is the patch's, and undoable; the recordings are the session's.
  public func loadInstrument(_ urls: [URL], into moduleId: String) async {
    let urls = Array(urls.prefix(128))
    guard !urls.isEmpty else { return }
    loading.insert(moduleId)
    loadFailure = nil
    defer { loading.remove(moduleId) }
    switch await decode(urls) {
    case .failure(let error):
      loadFailed(error, into: moduleId)
    case .success(let decoded):
      guard patch.modules.contains(where: { $0.id == moduleId }) else { return }
      let audio = decoded.map { SampleMath.normalise(SampleMath.toMono($0)) }
      let names = urls.map { SampleMath.name($0.lastPathComponent) }
      let zones = Multisample.zones(names: names, sampleRate: host.sampleRate)
      for slot in held[moduleId] ?? [] { hold(moduleId, slot, nil) }
      for (index, recording) in audio.enumerated() { hold(moduleId, "sample\(index)", recording) }
      recordings[moduleId] = zip(names, audio).map { name, recording in
        Recording(
          name: name, seconds: Double(recording.count) / host.sampleRate,
          peaks: SampleMath.waveformPeaks(recording, buckets: 48))
      }
      setData(moduleId, "zones", to: MultisampleZone.pack(zones), name: "Load Instrument")
      endTurn()
    }
  }

  /// A recording into an Audio Track: stereo, or mono on both sides, at its own level, playing
  /// from where the track is set to start.
  public func loadTrack(_ url: URL, into moduleId: String) async {
    loading.insert(moduleId)
    loadFailure = nil
    defer { loading.remove(moduleId) }
    switch await decode([url]) {
    case .failure(let error):
      loadFailed(error, into: moduleId)
    case .success(let decoded):
      guard patch.modules.contains(where: { $0.id == moduleId }), let channels = decoded.first,
        let left = channels.first
      else { return }
      let right = channels.count > 1 ? channels[1] : left
      hold(moduleId, "left", left)
      hold(moduleId, "right", right)
      hold(moduleId, "sampleRate", [Float(host.sampleRate)])
      tracks[moduleId] = Recording(
        name: SampleMath.name(url.lastPathComponent), seconds: Double(left.count) / host.sampleRate,
        stereo: channels.count > 1, peaks: SampleMath.waveformPeaks(SampleMath.toMono([left, right])))
    }
  }

  /// The loop taken to be a different number of bars: the tempo follows.
  public func setSampleBars(_ moduleId: String, _ bars: Int) {
    guard var info = samples[moduleId], bars > 0 else { return }
    info.bars = bars
    samples[moduleId] = info
    setTempo(SampleMath.tempoForBars(info.seconds, bars))
    endTurn()
  }

  // MARK: Transport

  /// The patch's own tempo, else its song's, else 120: what the transport runs at.
  public var tempo: Double { patch.tempo ?? song?.bpm ?? 120 }
  /// The song's swing, which the rack's transport shuffles by, as the reference's rack mode does.
  public var swing: Double { song?.swing ?? 0 }

  // MARK: The song

  /// The groovebox song the patch carries, if this build can read it: kept decoded, and decoded
  /// again only when its text changes.
  public var song: Song? {
    if decodedText != patch.groovebox {
      decodedText = patch.groovebox
      decoded = patch.groovebox.flatMap(SongCodec.decode)
    }
    return decoded
  }
  @ObservationIgnored private var decodedText: String?
  @ObservationIgnored private var decoded: Song?
  /// The song the host was last given, so an edit to the rack alone sends it nothing.
  @ObservationIgnored private var sentSong: Song?
  /// Where its every step starts, made once a song rather than thirty times a second.
  @ObservationIgnored private var songTimeline = Timeline()

  /// What saving this document keeps, which is what the rack says about it.
  public var compatibility: PatchCompatibility { patch.compatibility }
  /// What the rack says about a document it did not author, if anything.
  public var notice: DocumentNotice? {
    DocumentNotice.notice(compatibility, song: song.map { ($0.patterns.count, $0.bpm) })
  }

  /// Whether the rack's song is open in the groovebox, its edits coming straight back. Set by the
  /// app as it links them; `onUnlinkSong` is how the rack asks it to let go.
  public var songLinked = false
  @ObservationIgnored public var onUnlinkSong: (() -> Void)?
  /// The bars of the song being looped, if any.
  public private(set) var songLoop: (start: Int, bars: Int)?
  /// Which bar the song is on while it plays, for the face; read with the meters.
  public private(set) var songBar: Int?

  /// A song, whole, in the rack: its document with the groovebox source its machines come in by,
  /// rather than the song taken apart into modules.
  public func openSong(_ song: Song, name: String) {
    open(Patch.embedding(song: SongCodec.encode(song)), name: name)
  }

  /// Start the song at `bar`, and the rack with it if it was not running: a song jumped into
  /// against a rack that is not running would play alone, on a clock nothing else follows.
  public func startSong(atBar bar: Int) {
    guard live, let song = playedSong else { return }
    sendSong()
    let bar = Self.clampBar(bar, song.bars)
    if !running { toggleRunning() }
    host.startSong(atFrame: Int((songTimeline.start(ofBar: bar) * host.sampleRate).rounded()))
  }

  /// Loop `bars` bars from `start`, as much of them as the song has after it.
  public func loopSong(start: Int, bars: Int) {
    guard let song = playedSong else { return }
    let loop = Self.clampLoop(start, bars, song.bars)
    songLoop = loop
    if live { host.loopSong(startBar: loop.start, bars: loop.bars) }
  }

  public func clearSongLoop() {
    songLoop = nil
    if live { host.loopSong(startBar: 0, bars: 0) }
  }

  /// The first bar and the last one there is: the reference's `clampBar`.
  public static func clampBar(_ bar: Int, _ total: Int) -> Int { max(0, min(max(1, total) - 1, bar)) }

  /// A loop that fits inside the song after its start: the reference's `clampLoop`.
  public static func clampLoop(_ start: Int, _ bars: Int, _ total: Int) -> (start: Int, bars: Int) {
    let start = clampBar(start, total)
    return (start, max(1, min(max(1, total) - start, bars)))
  }

  /// An edit from the groovebox: the song changes in place and plays on where it was. Not a step of
  /// the rack's undo; the groovebox's own undo has it.
  public func songEdited(_ edited: Song) {
    patch.groovebox = SongCodec.encode(edited)
    sendSong()
    if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
    save()
  }

  /// The song as the rack plays it: at the patch's tempo when it sets one.
  public var playedSong: Song? {
    var played = song
    if let tempo = patch.tempo { played?.bpm = tempo }
    return played
  }

  /// Hand the host the patch's song, at the patch's tempo when it sets one, if it is not the one
  /// it has: the rack plays it beside itself, its machines on the `groovebox` module's buses.
  private func sendSong() {
    guard live else { return }
    let next = playedSong
    guard next != sentSong else { return }
    sentSong = next
    songTimeline = next.map { Timeline(song: $0) } ?? Timeline()
    host.setSong(next)
  }

  public func setTempo(_ bpm: Double) {
    // To a hundredth, which is how a tempo worked out from a loop's length is kept.
    let bpm = max(20, min(300, (bpm * 100).rounded() / 100))
    guard bpm != tempo else { return }
    if turning != "tempo" {
      record("Set Tempo")
      turning = "tempo"
    }
    patch.tempo = bpm
    if live {
      sendSong()
      host.setTransport(tempo: bpm, running: running, shuffle: swing)
    }
    save()
  }

  public func toggleRunning() {
    running.toggle()
    if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
  }

  /// Run or stop as an app the rack plays inside already has it, on the render thread, where its
  /// transport is: the session's word brought into line, without the rewind to the top a start of
  /// its own makes.
  public func follow(running: Bool) {
    guard running != self.running else { return }
    self.running = running
    if live { host.setTransport(tempo: tempo, running: running, shuffle: swing, located: true) }
  }

  // MARK: Keys

  public var voices: Int { max(1, min(8, Int(patch.voices ?? 1))) }

  /// Whether the rack is the one in front, so MIDI from outside comes here rather than to the
  /// groovebox: its window key on the Mac, or shown in the window's place on Windows.
  public var inFront = false
  /// The groovebox's session hands MIDI on while the rack is in front.
  public var takesMIDI: Bool { inFront }
  /// The MIDI sources there are, for the MIDI module's face to say whether it is listening.
  public var midiSources: [String] = []

  public func noteDown(_ note: Int, velocity: Double = 0.8, channel: Int = 1) {
    var keyboard = keyboards[channel] ?? RackKeyboard(voices: voices)
    let changes = keyboard.down(note, velocity: velocity)
    keyboards[channel] = keyboard
    for state in changes { play(state, channel: channel) }
    sounding = keyboards.values.flatMap(\.playing)
  }

  public func noteUp(_ note: Int, channel: Int = 1) {
    guard var keyboard = keyboards[channel] else { return }
    let changes = keyboard.up(note)
    keyboards[channel] = keyboard
    for state in changes { play(state, channel: channel) }
    sounding = keyboards.values.flatMap(\.playing)
  }

  /// Every note off on one channel, or on all of them.
  public func allNotesOff(channel: Int? = nil) {
    for (at, keyboard) in keyboards where channel == nil || at == channel {
      var keyboard = keyboard
      let changes = keyboard.allOff()
      keyboards[at] = keyboard
      for state in changes { play(state, channel: at) }
    }
    sounding = keyboards.values.flatMap(\.playing)
  }

  /// A channel message from a MIDI cable: notes through that channel's keyboard, and the mod
  /// wheel, bend, pressure, expression, breath and sustain straight to the modules listening,
  /// on every voice — one wheel moves every note.
  public func midi(_ bytes: [UInt8]) {
    for event in RackMIDI.events(bytes) {
      switch event {
      case .down(let note, let velocity, let channel): noteDown(note, velocity: velocity, channel: channel)
      case .up(let note, let channel): noteUp(note, channel: channel)
      case .allOff(let channel): allNotesOff(channel: channel)
      case .performance(let control, let value, let channel):
        guard live else { continue }
        for module in listening(on: channel) { host.setParam(module.id, control.rawValue, value) }
      case .control(let cc, let value, let channel):
        control(cc, value, channel: channel)
      }
    }
  }

  /// The MIDI modules that hear `channel`: those on it, and those on all of them.
  private func listening(on channel: Int) -> [PatchModule] {
    patch.modules.filter { module in
      guard module.type == "midi" else { return false }
      let wanted = Int(module.params["channel"] ?? 0)
      return wanted == 0 || wanted == channel
    }
  }

  /// One voice's note to every MIDI module listening on its channel.
  private func play(_ state: RackKeyboard.VoiceState, channel: Int) {
    if state.gate == 1 { lastNote = state.note }
    guard live else { return }
    for module in listening(on: channel) {
      host.setParam(module.id, "note", Double(state.note), voice: state.voice)
      host.setParam(module.id, "gate", Double(state.gate), voice: state.voice)
      host.setParam(module.id, "velocity", state.velocity, voice: state.voice)
    }
  }

  // MARK: Ids

  public static func freshId(_ patch: Patch, _ type: String) -> String {
    let taken = Set(patch.modules.map(\.id))
    var n = 1
    while taken.contains("\(type)-\(n)") { n += 1 }
    return "\(type)-\(n)"
  }
}
