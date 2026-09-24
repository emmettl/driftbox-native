#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxRack
  import DriftboxSeq
  import Foundation
  import Observation

  /// The rack as the window edits it: the patch, what is selected, which side is showing, the
  /// transport, the keys being played, and an undo history — with a real-time host behind it that
  /// every edit reaches. The edits are the reference store's, one for one: a structural one
  /// recompiles the patch, a knob only moves its slot.
  @MainActor @Observable
  public final class RackModel {
    /// What the rack is playing and showing.
    private(set) var patch: Patch
    /// The factory patch it came from, if it did, for the header to name.
    private(set) var name: String
    private(set) var selection: Set<String> = []
    /// Showing the back, where the jacks and cables are.
    private(set) var flipped = false
    /// When the rack last turned round, which the cables swing from.
    private(set) var flippedAt: Date?
    private(set) var running = false
    /// The last note the keys played, for the MIDI module's panel to show.
    private(set) var lastNote: Int?
    private(set) var sounding: [Int] = []
    /// Cables the compiler had to delay a block to break a cycle, and ones folding stereo to mono.
    private(set) var delayed: Set<String> = []
    private(set) var folded: Set<String> = []
    /// What the metered modules are showing, by id: refreshed thirty times a second once
    /// something renders the rack. Only the faceplates that read it redraw when it changes.
    private(set) var readings: [String: MeterReading] = [:]
    /// What each sampler is playing that the patch does not carry: a file, or the patch's break.
    /// The audio itself is the host's; this is what the faces say about it.
    private(set) var samples: [String: SampleInfo] = [:]
    /// Each Multisampler's recordings, zone by zone, and each Audio Track's file: what their faces
    /// say about audio the host holds.
    private(set) var recordings: [String: [Recording]] = [:]
    private(set) var tracks: [String: Recording] = [:]
    /// Modules with files being read into them.
    private(set) var loading: Set<String> = []
    /// Why the last file could not be loaded, for the face that asked.
    private(set) var loadFailure: (module: String, reason: String)?
    /// Why the rack cannot be heard, if its audio unit could not be made.
    private(set) var startFailure: String?
    /// The Combinator whose routing is open beside the rack. Where the window is, not what the
    /// patch is, so it is never saved.
    private(set) var editingRoutes: String?
    /// What the controllers on the desk have been taught: kept beside the patch, never in it.
    private(set) var ccBindings: [RackCC.Binding] = []
    /// The param waiting for a controller to be turned, if one is.
    private(set) var ccLearning: PortReference?
    /// Where each `plugin` module's unit has got to, for its face. None for a module with no
    /// unit chosen.
    private(set) var plugins: [String: PluginStatus] = [:]
    /// The macro waiting for a param to be moved in its unit's interface, if one is.
    private(set) var learning: (module: String, macro: Int)?

    enum PluginStatus: Equatable {
      case loading
      /// Playing, and how late its output is, in seconds.
      case ready(latency: Double)
      /// Not on this Mac: kept in the patch as it was, and silent.
      case missing
      case failed(String)
    }

    // MARK: History

    private struct Entry {
      var patch: Patch
      var name: String
    }
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    /// The knob being turned, so one turn is one step of undo however many values it passed.
    private var turning: String?
    static let historyLimit = 64

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }

    // MARK: Sound

    @ObservationIgnored let host: RackHost
    /// A keyboard for each MIDI channel notes arrive on — the typing keys are channel 1 — so two
    /// controllers on two channels do not steal each other's voices.
    @ObservationIgnored private var keyboards: [Int: RackKeyboard] = [:]
    @ObservationIgnored private var node: AVAudioUnit?
    /// The rack's Audio Unit, once it is made, and whether it is being.
    @ObservationIgnored private(set) var unit: RackAudioUnit?
    @ObservationIgnored private var attaching = false
    /// Whether anything renders the host. Until something does, nothing drains its command ring,
    /// so nothing is sent to it; whatever is there is loaded the moment something starts to.
    @ObservationIgnored private(set) var live = false
    @ObservationIgnored private var metering: Timer?
    /// Each break rendered once, at the host's rate, off the main thread: a fifth of a second
    /// the window would otherwise stop for.
    @ObservationIgnored private var breaks: [String: [Float]] = [:]
    @ObservationIgnored private var rendering: [String: Task<Void, Never>] = [:]
    /// The host slots each module has audio in, so a module that goes takes its audio with it.
    @ObservationIgnored private var held: [String: Set<String>] = [:]
    /// Each `plugin` module's unit, once made, and which unit it is: a module given a different
    /// one gets a new instance, and one given the same keeps its own through any edit.
    @ObservationIgnored private(set) var units: [String: HostedAudioUnit] = [:]
    @ObservationIgnored private var unitIds: [String: String] = [:]
    @ObservationIgnored private var making: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var watching: [String: AUParameterObserverToken] = [:]
    /// Units changed since their state was last taken into the patch.
    @ObservationIgnored private var changedUnits: Set<String> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Each unit's own interface, while it is open.
    @ObservationIgnored var interfaces: [String: PluginInterface] = [:]

    /// A recording, for a face: its name, how long, whether stereo, and its shape.
    struct Recording: Equatable {
      var name: String
      var seconds: Double
      var stereo = false
      var peaks: [Double]
    }
    /// Where the patch is kept between launches; nil for a model made in a test.
    @ObservationIgnored var memory: UserDefaults?

    /// A rack on a host of its own, not yet making sound: `attach` gives it somewhere to go.
    public init(sampleRate: Double = 48000, memory: UserDefaults? = nil) {
      host = RackHost(sampleRate: sampleRate)
      self.memory = memory
      let saved = memory?.string(forKey: Self.savedKey).flatMap(PatchCodec.decode)
      let first = PatchEntry.all.first { $0.id == Self.firstPatch }
      patch = saved ?? first?.load() ?? Patch(modules: [], cables: [])
      name =
        saved == nil ? first?.name ?? "Untitled" : memory?.string(forKey: Self.savedNameKey) ?? "Untitled"
      ccBindings = RackCC.load(memory)
      patch = applyModulation(patch, registry: RackModules.registry)
      rebuild()
    }

    static let savedKey = "rack.patch"
    static let savedNameKey = "rack.name"
    /// A small, tempo-synced instrument that plays without a break to load.
    static let firstPatch = "pocket-sequence"

    /// Play through `engine`: the rack's Audio Unit, made once, playing the host. Asynchronous,
    /// as making an audio unit is; the rack is heard from when it arrives.
    public func attach(to engine: AVAudioEngine) {
      guard unit == nil, !attaching else { return }
      attaching = true
      _ = Self.registered
      AVAudioUnit.instantiate(with: RackAudioUnit.componentDescription, options: []) {
        [weak self] made, failure in
        Task { @MainActor in self?.attached(made, failure, to: engine) }
      }
    }

    /// The unit registered in this process, once, as the engine's is.
    private static let registered: Void = AUAudioUnit.registerSubclass(
      RackAudioUnit.self, as: RackAudioUnit.componentDescription, name: "Driftbox Rack", version: 1)

    private func attached(_ made: AVAudioUnit?, _ failure: Error?, to engine: AVAudioEngine) {
      attaching = false
      guard let made, let unit = made.auAudioUnit as? RackAudioUnit else {
        startFailure = failure?.localizedDescription ?? "its audio unit could not be made"
        return
      }
      unit.host = host
      unit.restore = { [weak self] document, name in
        Task { @MainActor in self?.restore(document, name: name) }
      }
      engine.attach(made)
      engine.connect(made, to: engine.mainMixerNode, format: made.outputFormat(forBus: 0))
      node = made
      self.unit = unit
      save()
      listen()
    }

    /// A state a plug-in host saved, opened as the rack's patch.
    private func restore(_ document: String, name: String?) {
      guard let patch = PatchCodec.decode(document) else { return }
      open(patch, name: name ?? "Untitled")
    }

    /// Something renders the host from now on: hand it the patch, the transport and the notes.
    func listen() {
      guard !live else { return }
      live = true
      host.load(patch)
      sendSong()
      if let loop = songLoop { host.loopSong(startBar: loop.start, bars: loop.bars) }
      host.setTransport(tempo: tempo, running: running, shuffle: swing)
      metering = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshReadings() }
      }
    }

    /// Take the host's latest readings.
    func refreshReadings() {
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
    func open(_ patch: Patch, name: String) {
      allNotesOff()
      if songLinked {
        groovebox?.unlinkRack()
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
      turning = nil
      rebuild()
      if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
    }

    func open(_ entry: PatchEntry) {
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
      unit?.saved.withLock { $0 = (PatchCodec.encode(patch), name) }
      guard let memory else { return }
      memory.set(PatchCodec.encode(patch), forKey: Self.savedKey)
      memory.set(name, forKey: Self.savedNameKey)
    }

    static func key(_ cable: PatchCable) -> String {
      Cable.key(from: (cable.from.module, cable.from.port), to: (cable.to.module, cable.to.port))
    }

    /// A knob's value, or its default.
    func value(_ module: PatchModule, _ param: ParamDef) -> Double {
      module.params[param.id] ?? param.defaultValue
    }

    /// Turn a knob, now. The first move of a turn is what undo goes back to; the rest join it.
    /// The routings run over the result, so a rotary turns everything it drives as it turns; a
    /// knob a routing drives, turned by hand, is taken straight back — the routing owns it, and
    /// its face says so — and that is no edit at all.
    func turn(_ moduleId: String, _ param: String, to value: Double) {
      guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
      var next = patch
      next.modules[at].params[param] = value
      next = applyModulation(next, registry: RackModules.registry)
      guard next != patch else { return }
      let key = "\(moduleId)/\(param)"
      if turning != key {
        let name =
          RackModules.registry[patch.modules[at].type]?.params.first { $0.id == param }?.name ?? param
        record("Set \(name)")
        turning = key
      }
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
    func trim(_ moduleId: String, _ inlet: String) -> Double {
      patch.modules.first { $0.id == moduleId }?.inputTrims[inlet] ?? 1
    }

    /// Turn an inlet's trim pot, as a knob turns: one drag is one step of undo, and the sound
    /// hears it without a rebuild — except where the pot leaves unity or comes back to it. Only
    /// a pot doing something costs the graph a buffer and a multiply, so those two moments change
    /// the plan's shape, and are one rebuild each; unity is kept as no trim at all.
    func setTrim(_ moduleId: String, _ inlet: String, to value: Double) {
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
    func setData(_ moduleId: String, _ slot: String, to values: [Double], name: String = "Edit Pattern") {
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
    func endTurn() { turning = nil }

    /// A selector's choice: one step of undo on its own.
    func set(_ moduleId: String, _ param: String, to value: Double) {
      turn(moduleId, param, to: value)
      endTurn()
    }

    /// A module at the end of the rack, with an Out of its own when it is a source, as the
    /// reference adds one.
    @discardableResult
    func add(_ type: String) -> String? {
      guard let def = RackModules.registry[type] else { return nil }
      let id = Self.freshId(patch, type)
      structural("Add \(def.name)") { patch in
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
        patch.modules.append(PatchModule(id: id, type: type))
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
    func duplicate(_ moduleId: String) {
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
    func remove(_ moduleId: String) {
      structural("Remove Module") { patch in
        patch.modules.removeAll { $0.id == moduleId }
        patch.cables.removeAll { $0.from.module == moduleId || $0.to.module == moduleId }
        patch.modulation.removeAll { $0.from.module == moduleId || $0.to.module == moduleId }
      }
      selection.remove(moduleId)
    }

    func setBypassed(_ moduleId: String, _ bypassed: Bool) {
      structural(bypassed ? "Bypass" : "Unbypass") { patch in
        guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
        patch.modules[at].bypassed = bypassed
      }
    }

    /// A module moved to insertion index `index` of the rack as it is.
    func drop(_ moduleId: String, at index: Int) {
      guard let from = patch.modules.firstIndex(where: { $0.id == moduleId }),
        let modules = RackLayout.reordered(patch.modules, from: from, to: index)
      else { return }
      structural("Move Module") { $0.modules = modules }
    }

    func move(_ moduleId: String, by offset: Int) {
      guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
      let to = at + offset
      guard to >= 0, to < patch.modules.count else { return }
      structural("Move Module") { patch in
        let module = patch.modules.remove(at: at)
        patch.modules.insert(module, at: to)
      }
    }

    /// A cable from an outlet to an inlet. One cable per inlet: whatever was there goes.
    func connect(_ from: PortReference, _ to: PortReference) {
      structural("Connect") { patch in
        patch.cables.removeAll { $0.to == to }
        patch.cables.append(PatchCable(from: from, to: to))
      }
    }

    func disconnect(_ cable: PatchCable) {
      structural("Disconnect") { $0.cables.removeAll { $0 == cable } }
    }

    // MARK: Routing

    /// Open one Combinator's routing beside the rack, or close it.
    func editRoutes(_ moduleId: String?) { editingRoutes = moduleId }

    /// The params a routing can drive: any a hand could set. The hidden ones are written by the
    /// host — the MIDI module's note — and a routing would be a second writer.
    static func routable(_ type: String) -> [ParamDef] {
      RackModules.registry[type]?.params.filter { !$0.hidden } ?? []
    }

    /// Whether a routing drives this knob, for its face to mark it.
    func isRouted(_ moduleId: String, _ param: String) -> Bool {
      patch.modulation.contains { $0.to.module == moduleId && $0.to.port == param }
    }

    /// Where a new routing from `combi` points: a filter's cutoff if there is one, since that is
    /// what most first routings are for, or else the first knob of the first other module.
    func defaultTarget(_ combi: String) -> PortReference? {
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
    func addRoute(_ combi: String) {
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
    func setRoute(_ index: Int, _ change: (inout ModRoute) -> Void) {
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

    func removeRoute(_ index: Int) {
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
    func startCcLearn(_ moduleId: String, _ param: String) { ccLearning = PortReference(moduleId, param) }

    func cancelCcLearn() { ccLearning = nil }

    /// Teach the armed param controller `cc`, on any channel. Nothing armed, nothing learnt.
    func finishCcLearn(_ cc: Int) {
      guard let armed = ccLearning else { return }
      ccBindings = RackCC.learn(ccBindings, RackCC.Binding(cc: cc, module: armed.module, param: armed.port))
      ccLearning = nil
      RackCC.save(ccBindings, to: memory)
    }

    /// Forget what a param learnt: re-learning cannot unbind, so a mistake needs a way out.
    func clearCcBinding(_ moduleId: String, _ param: String) {
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

    func select(_ moduleId: String?, adding: Bool = false) {
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

    func flip() {
      flipped.toggle()
      flippedAt = Date()
    }

    // MARK: Undo

    func undo() {
      guard let entry = undoStack.popLast() else { return }
      redoStack.append(Entry(patch: patch, name: entry.name))
      restore(entry.patch)
    }

    func redo() {
      guard let entry = redoStack.popLast() else { return }
      undoStack.append(Entry(patch: patch, name: entry.name))
      restore(entry.patch)
    }

    private func restore(_ patch: Patch) {
      turning = nil
      // The song's history is the groovebox window's, so going back in the rack's keeps the song
      // as it is now rather than as it was when the rack last changed.
      var patch = patch
      patch.groovebox = self.patch.groovebox
      self.patch = patch
      selection = selection.filter { id in patch.modules.contains { $0.id == id } }
      rebuild()
    }

    // MARK: Plug-ins

    /// Give a `plugin` module a unit: a structural edit, undone like any other.
    func choosePlugin(_ moduleId: String, _ reference: PluginReference) {
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
      guard reference.format == "audio-unit", let component = HostedAudioUnit.component(reference.id) else {
        plugins[id] = .missing
        return
      }
      plugins[id] = .loading
      let rate = host.sampleRate
      making[id] = Task { [weak self] in
        let made: Result<HostedAudioUnit, Error>
        do {
          made = .success(
            try await HostedAudioUnit.instantiate(component, sampleRate: rate, state: reference.state))
        } catch {
          made = .failure(error)
        }
        guard let self, !Task.isCancelled, unitIds[id] == reference.id else { return }
        making[id] = nil
        switch made {
        case .success(let unit):
          units[id] = unit
          applyMacros(id)
          host.setExternal(id, unit.external)
          plugins[id] = .ready(latency: unit.latency)
          watch(id, unit)
        case .failure(HostedAudioUnit.Failure.missing):
          plugins[id] = .missing
        case .failure(let error):
          plugins[id] = .failed(
            (error as? HostedAudioUnit.Failure) == .format
              ? "It will not play in stereo at \(Int(rate)) Hz" : error.localizedDescription)
        }
      }
    }

    /// A unit let go of: silent in the host at once, its interface closed, its state taken first.
    private func dropUnit(_ id: String) {
      making.removeValue(forKey: id)?.cancel()
      interfaces.removeValue(forKey: id)?.close()
      if let unit = units[id], let token = watching[id] {
        unit.unit.parameterTree?.removeParameterObserver(token)
      }
      host.setExternal(id, nil)
      units[id] = nil
      unitIds[id] = nil
      watching[id] = nil
      changedUnits.remove(id)
      plugins[id] = nil
      if learning?.module == id { learning = nil }
    }

    /// Hear about a unit being changed — from its interface, or anything else that sets its
    /// params — so its state reaches the patch soon after.
    private func watch(_ id: String, _ unit: HostedAudioUnit) {
      watching[id] = unit.unit.parameterTree?.token(
        byAddingParameterObserver: Self.observer { [weak self] address in
          self?.unitChanged(id)
          self?.learned(id, address)
        })
    }

    /// An observer for a unit to call on whatever thread it likes, which a closure written here, on
    /// the main actor, would trap on: it hands the param moved to the main actor instead.
    nonisolated private static func observer(
      _ changed: @escaping @MainActor @Sendable (AUParameterAddress) -> Void
    ) -> AUParameterObserver {
      { address, _ in Task { @MainActor in changed(address) } }
    }

    /// A unit's state is out of date in the patch: saved once things have been still for a moment.
    func unitChanged(_ id: String) {
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

    /// Map macro `macro` (1 to 4) of a plug-in module onto one of its unit's params, or unmap it
    /// (nil). One step of undo; the knob moves to where the param already is, so nothing jumps.
    func mapMacro(_ moduleId: String, _ macro: Int, to parameter: AUParameter?) {
      guard (1...4).contains(macro), let at = patch.modules.firstIndex(where: { $0.id == moduleId }),
        patch.modules[at].plugin != nil
      else { return }
      var next = patch
      var controls = next.modules[at].plugin?.controls.filter { $0.macro != macro } ?? []
      if let parameter {
        controls.append(PluginControl(macro: macro, key: parameter.keyPath, name: parameter.displayName))
        controls.sort { $0.macro < $1.macro }
        next.modules[at].params["macro\(macro)"] = HostedAudioUnit.fraction(of: parameter)
      }
      next.modules[at].plugin?.controls = controls
      guard next != patch else { return }
      record(parameter == nil ? "Unmap Macro \(macro)" : "Map Macro \(macro)")
      settle(next)
      applyMacros(moduleId)
      save()
    }

    /// Map the next param moved in the unit's own interface onto macro `macro`, opening it.
    func learnMacro(_ moduleId: String, _ macro: Int, open: Bool = true) {
      learning = (moduleId, macro)
      if open { showInterface(moduleId) }
    }

    func cancelLearning() { learning = nil }

    /// A param moved in a unit, while one of its module's macros is waiting for one. The params its
    /// other macros already turn are not learnt: they move when those macros do.
    private func learned(_ moduleId: String, _ address: AUParameterAddress) {
      guard let learning, learning.module == moduleId, let unit = units[moduleId],
        let parameter = unit.parameters.values.first(where: { $0.address == address }),
        let module = patch.modules.first(where: { $0.id == moduleId })
      else { return }
      let others = (module.plugin?.controls ?? []).filter { $0.macro != learning.macro }.map(\.key)
      guard !others.contains(parameter.keyPath) else { return }
      self.learning = nil
      mapMacro(moduleId, learning.macro, to: parameter)
    }

    /// The param each of a unit's macros turns, found by key in the unit, into the host's mapping.
    private func applyMacros(_ moduleId: String) {
      guard let unit = units[moduleId],
        let controls = patch.modules.first(where: { $0.id == moduleId })?.plugin?.controls
      else { return }
      let parameters = unit.parameters
      for macro in 1...4 {
        unit.map(macro - 1, to: controls.first { $0.macro == macro }.flatMap { parameters[$0.key] })
      }
    }

    /// What macro `macro` of a module turns: the param, when its unit has it.
    func macroParameter(_ moduleId: String, _ macro: Int) -> (
      control: PluginControl, parameter: AUParameter?
    )? {
      guard
        let control = patch.modules.first(where: { $0.id == moduleId })?.plugin?.controls
          .first(where: { $0.macro == macro })
      else { return nil }
      return (control, units[moduleId]?.parameters[control.key])
    }

    /// Once every unit being made has arrived.
    func pluginsReady() async {
      while let task = making.values.first { await task.value }
    }

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
    func breaksReady() async {
      while let task = rendering.values.first { await task.value }
    }

    /// Read an audio file into a sampler: at the rack's rate, mono, its loudest sample 0.9. The
    /// rack's tempo becomes the one at which the file is a whole number of bars — whichever of one,
    /// two, four or eight is nearest the tempo it had — and the transport starts, as the reference
    /// does, so the loop is heard in time at once.
    func load(_ url: URL, into moduleId: String) async {
      loading.insert(moduleId)
      loadFailure = nil
      defer { loading.remove(moduleId) }
      let rate = host.sampleRate
      let decoded = await Task.detached(priority: .userInitiated) { () -> Result<[Float], Error> in
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return Result {
          SampleMath.normalise(SampleMath.toMono(try SampleMath.decode(url, sampleRate: rate)))
        }
      }.value
      switch decoded {
      case .failure(let error):
        loadFailure = (moduleId, error.localizedDescription)
      case .success(let audio):
        guard patch.modules.contains(where: { $0.id == moduleId }), audio.count > 1 else { return }
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
      return await Task.detached(priority: .userInitiated) {
        Result {
          try urls.map { url in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try SampleMath.decode(url, sampleRate: rate)
          }
        }
      }.value
    }

    /// A set of recordings into a Multisampler, mapped by their names — Piano_C3_pp maps itself —
    /// each mono and loud. The map is the patch's, and undoable; the recordings are the session's.
    func loadInstrument(_ urls: [URL], into moduleId: String) async {
      let urls = Array(urls.prefix(128))
      guard !urls.isEmpty else { return }
      loading.insert(moduleId)
      loadFailure = nil
      defer { loading.remove(moduleId) }
      switch await decode(urls) {
      case .failure(let error):
        loadFailure = (moduleId, error.localizedDescription)
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
    func loadTrack(_ url: URL, into moduleId: String) async {
      loading.insert(moduleId)
      loadFailure = nil
      defer { loading.remove(moduleId) }
      switch await decode([url]) {
      case .failure(let error):
        loadFailure = (moduleId, error.localizedDescription)
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
    func setSampleBars(_ moduleId: String, _ bars: Int) {
      guard var info = samples[moduleId], bars > 0 else { return }
      info.bars = bars
      samples[moduleId] = info
      setTempo(SampleMath.tempoForBars(info.seconds, bars))
      endTurn()
    }

    // MARK: Transport

    /// The patch's own tempo, else its song's, else 120: what the transport runs at.
    var tempo: Double { patch.tempo ?? song?.bpm ?? 120 }
    /// The song's swing, which the rack's transport shuffles by, as the reference's rack mode does.
    var swing: Double { song?.swing ?? 0 }

    // MARK: The song

    /// The groovebox song the patch carries, if this build can read it: kept decoded, and decoded
    /// again only when its text changes.
    var song: Song? {
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
    var compatibility: PatchCompatibility { patch.compatibility }
    /// What the rack says about a document it did not author, if anything.
    var notice: DocumentNotice? {
      DocumentNotice.notice(compatibility, song: song.map { ($0.patterns.count, $0.bpm) })
    }

    /// The groovebox window: the song in it, and where the rack's song is edited.
    @ObservationIgnored weak var groovebox: Player?
    /// Whether the rack's song is open in the groovebox window, its edits coming straight back.
    private(set) var songLinked = false
    /// The bars of the song being looped, if any.
    private(set) var songLoop: (start: Int, bars: Int)?
    /// Which bar the song is on while it plays, for the face; read with the meters.
    private(set) var songBar: Int?

    /// A song, whole, in the rack: its document with the groovebox source its machines come in by,
    /// rather than the song taken apart into modules.
    func openSong(_ song: Song, name: String) {
      open(Patch.embedding(song: SongCodec.encode(song)), name: name)
    }

    /// Start the song at `bar`, and the rack with it if it was not running: a song jumped into
    /// against a rack that is not running would play alone, on a clock nothing else follows.
    func startSong(atBar bar: Int) {
      guard live, let song = playedSong else { return }
      sendSong()
      let bar = Self.clampBar(bar, song.bars)
      if !running { toggleRunning() }
      host.startSong(atFrame: Int((songTimeline.start(ofBar: bar) * host.sampleRate).rounded()))
    }

    /// Loop `bars` bars from `start`, as much of them as the song has after it.
    func loopSong(start: Int, bars: Int) {
      guard let song = playedSong else { return }
      let loop = Self.clampLoop(start, bars, song.bars)
      songLoop = loop
      if live { host.loopSong(startBar: loop.start, bars: loop.bars) }
    }

    func clearSongLoop() {
      songLoop = nil
      if live { host.loopSong(startBar: 0, bars: 0) }
    }

    /// The first bar and the last one there is: the reference's `clampBar`.
    static func clampBar(_ bar: Int, _ total: Int) -> Int { max(0, min(max(1, total) - 1, bar)) }

    /// A loop that fits inside the song after its start: the reference's `clampLoop`.
    static func clampLoop(_ start: Int, _ bars: Int, _ total: Int) -> (start: Int, bars: Int) {
      let start = clampBar(start, total)
      return (start, max(1, min(max(1, total) - start, bars)))
    }

    /// Open the rack's song in the groovebox window to edit it there. Asks first if the window
    /// has work it would lose.
    func editInGroovebox() {
      guard let groovebox, let song else { return }
      guard SongFiles(player: groovebox).confirmDiscard() else { return }
      groovebox.link(
        song, name: name,
        edited: { [weak self] edited in self?.songEdited(edited) },
        ended: { [weak self] in self?.songLinked = false })
      songLinked = true
    }

    /// An edit from the groovebox window: the song changes in place and plays on where it was.
    /// Not a step of the rack's undo; the window's own undo has it.
    private func songEdited(_ edited: Song) {
      patch.groovebox = SongCodec.encode(edited)
      sendSong()
      if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
      save()
    }

    /// The song as the rack plays it: at the patch's tempo when it sets one.
    var playedSong: Song? {
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

    func setTempo(_ bpm: Double) {
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

    func toggleRunning() {
      running.toggle()
      if live { host.setTransport(tempo: tempo, running: running, shuffle: swing) }
    }

    // MARK: Keys

    var voices: Int { max(1, min(8, Int(patch.voices ?? 1))) }

    /// Whether the rack's window is the one in front, so MIDI from outside comes here rather
    /// than to the groovebox.
    var inFront = false
    /// The MIDI sources there are, for the MIDI module's face to say whether it is listening.
    var midiSources: [String] = []

    func noteDown(_ note: Int, velocity: Double = 0.8, channel: Int = 1) {
      var keyboard = keyboards[channel] ?? RackKeyboard(voices: voices)
      let changes = keyboard.down(note, velocity: velocity)
      keyboards[channel] = keyboard
      for state in changes { play(state, channel: channel) }
      sounding = keyboards.values.flatMap(\.playing)
    }

    func noteUp(_ note: Int, channel: Int = 1) {
      guard var keyboard = keyboards[channel] else { return }
      let changes = keyboard.up(note)
      keyboards[channel] = keyboard
      for state in changes { play(state, channel: channel) }
      sounding = keyboards.values.flatMap(\.playing)
    }

    /// Every note off on one channel, or on all of them.
    func allNotesOff(channel: Int? = nil) {
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
    func midi(_ bytes: [UInt8]) {
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

    static func freshId(_ patch: Patch, _ type: String) -> String {
      let taken = Set(patch.modules.map(\.id))
      var n = 1
      while taken.contains("\(type)-\(n)") { n += 1 }
      return "\(type)-\(n)"
    }
  }
#endif
