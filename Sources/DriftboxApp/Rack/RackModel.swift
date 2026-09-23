#if canImport(SwiftUI) && canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxRack
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
    /// Samplers with a file being read into them.
    private(set) var loading: Set<String> = []
    /// Why the last file could not be loaded, for the face that asked.
    private(set) var loadFailure: (module: String, reason: String)?

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
    @ObservationIgnored private var node: AVAudioSourceNode?
    /// Whether anything renders the host. Until something does, nothing drains its command ring,
    /// so nothing is sent to it; whatever is there is loaded the moment something starts to.
    @ObservationIgnored private(set) var live = false
    @ObservationIgnored private var metering: Timer?
    /// Each break rendered once, at the host's rate, off the main thread: a fifth of a second
    /// the window would otherwise stop for.
    @ObservationIgnored private var breaks: [String: [Float]] = [:]
    @ObservationIgnored private var rendering: [String: Task<Void, Never>] = [:]
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
      rebuild()
    }

    static let savedKey = "rack.patch"
    static let savedNameKey = "rack.name"
    /// A small, tempo-synced instrument that plays without a break to load.
    static let firstPatch = "pocket-sequence"

    /// Play through `mixer`'s engine: a source node rendering the host, made once.
    public func attach(to engine: AVAudioEngine) {
      guard node == nil else { return }
      let (node, format) = Self.source(host)
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      self.node = node
      listen()
    }

    /// A source node rendering `host`. Made outside the main actor so its render block is not
    /// taken to belong to it: the block runs on the audio thread, where a check that it was on
    /// the main one would stop the app.
    nonisolated private static func source(_ host: RackHost) -> (AVAudioSourceNode, AVAudioFormat) {
      let format = AVAudioFormat(standardFormatWithSampleRate: host.sampleRate, channels: 2)!
      let node = AVAudioSourceNode(format: format) { _, _, frames, buffers -> OSStatus in
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
          let right = list[1].mData?.assumingMemoryBound(to: Float.self)
        else { return noErr }
        host.render(frames: Int(frames), left: left, right: right)
        return noErr
      }
      return (node, format)
    }

    /// Something renders the host from now on: hand it the patch, the transport and the notes.
    func listen() {
      guard !live else { return }
      live = true
      host.load(patch)
      host.setTransport(tempo: tempo, running: running)
      metering = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshReadings() }
      }
    }

    /// Take the host's latest readings.
    func refreshReadings() {
      readings = host.readings()
    }

    // MARK: Opening

    /// Put a different patch in the rack. Its history is the old one's, so it starts afresh.
    func open(_ patch: Patch, name: String) {
      allNotesOff()
      // Another patch's samples are not this one's, even under the same ids.
      host.clearSamples()
      samples = [:]
      self.patch = patch
      self.name = name
      selection = []
      undoStack = []
      redoStack = []
      turning = nil
      rebuild()
      if live { host.setTransport(tempo: tempo, running: running) }
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
      let plan: Plan
      if live {
        host.load(patch)
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
    func turn(_ moduleId: String, _ param: String, to value: Double) {
      guard let at = patch.modules.firstIndex(where: { $0.id == moduleId }) else { return }
      let key = "\(moduleId)/\(param)"
      if turning != key {
        let name =
          RackModules.registry[patch.modules[at].type]?.params.first { $0.id == param }?.name ?? param
        record("Set \(name)")
        turning = key
      }
      patch.modules[at].params[param] = value
      if live { host.setParam(moduleId, param, value) }
      save()
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
      self.patch = patch
      selection = selection.filter { id in patch.modules.contains { $0.id == id } }
      rebuild()
    }

    // MARK: Samples

    /// Samplers gone from the patch lose their audio; samplers with none get the patch's break,
    /// as the reference gives every one of them on Start.
    private func settleSamples() {
      let samplers = Set(patch.modules.filter { $0.type == "sampler" }.map(\.id))
      for id in samples.keys where !samplers.contains(id) {
        host.setSample(id, "sample", nil)
        samples[id] = nil
      }
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
        host.setSample(module, "sample", audio)
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
        host.setSample(moduleId, "sample", audio)
        samples[moduleId] = SampleInfo(
          name: SampleMath.name(url.lastPathComponent), bars: bars, seconds: seconds,
          peaks: SampleMath.waveformPeaks(audio), source: .file)
        setTempo(SampleMath.tempoForBars(seconds, bars))
        endTurn()
        if !running { toggleRunning() }
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

    var tempo: Double { patch.tempo ?? 120 }

    func setTempo(_ bpm: Double) {
      // To a hundredth, which is how a tempo worked out from a loop's length is kept.
      let bpm = max(20, min(300, (bpm * 100).rounded() / 100))
      guard bpm != tempo else { return }
      if turning != "tempo" {
        record("Set Tempo")
        turning = "tempo"
      }
      patch.tempo = bpm
      if live { host.setTransport(tempo: bpm, running: running) }
      save()
    }

    func toggleRunning() {
      running.toggle()
      if live { host.setTransport(tempo: tempo, running: running) }
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
        case .control:
          break
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
