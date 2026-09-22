#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import DriftboxScenes
  import DriftboxSeq
  import Foundation
  import Observation

  /// The catalogue that ships with the app: the same documents the conformance fixtures hold.
  struct CatalogueEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let visual: String
  }

  enum Catalogue {
    static func entries() -> [CatalogueEntry] {
      struct File: Decodable {
        struct Entry: Decodable {
          let id: String
          let name: String
          let blurb: String
          let visual: String
        }
        let songs: [Entry]
      }
      guard let url = Bundle.module.url(forResource: "catalogue", withExtension: "json"),
        let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
      else { return [] }
      return file.songs.map { CatalogueEntry(id: $0.id, name: $0.name, blurb: $0.blurb, visual: $0.visual) }
    }

    static func song(_ id: String) -> Song? {
      guard let url = Bundle.module.url(forResource: id, withExtension: "song.json", subdirectory: "Songs"),
        let data = try? Data(contentsOf: url)
      else { return nil }
      return SongCodec.decode(String(decoding: data, as: UTF8.self))
    }
  }

  /// What the interface holds: the song being edited, the engine playing it, and where it is.
  @MainActor
  @Observable
  public final class Player {
    private(set) var entries = Catalogue.entries()
    private(set) var current: CatalogueEntry?
    var song: Song? {
      didSet { retime() }
    }
    private(set) var isPlaying = false
    /// Where the transport is, in the song's own frames.
    private(set) var songFrame = 0
    /// The engine's rate, which is the unit's and not the device's: the device can change under
    /// the unit, and the output converts.
    var sampleRate: Double { host?.sampleRate ?? 48000 }
    private(set) var error: String?
    /// The last voice struck, by index into `allVoices`, and when. Taken from the engine's
    /// events ring thirty times a second.
    private var lastHits: [Int: Int] = [:]
    /// The voices struck in the last tenth of a second, by index into `allVoices`: for anything
    /// that wants to flash.
    private(set) var struck: Set<Int> = []
    /// The engine's own clock, which the events are stamped in.
    private var engineFrame = 0
    /// Events since the scene last drew, kept for it here; the grid's flashes read `struck`.
    private var pendingEvents: [EngineEvent] = []
    /// Where the pad is being touched, for the scene's cursor.
    var padTouch: SIMD2<Float>?
    /// Whether the visuals pane is showing.
    var showsVisuals = true
    /// Where the song came from, if a file; where Save goes.
    private(set) var fileURL: URL?
    /// Whether the song has changed since it was opened or last saved: the window's edited dot,
    /// and what makes closing over the work ask first.
    private(set) var isEdited = false
    /// The song as it was opened or last saved, which is what edited is measured against: undoing
    /// back to it is not an edit, however many steps it took to get there.
    private var saved: Song?
    /// What to call the song: the catalogue entry's name, or the file's. A window with no song in
    /// it is not an untitled document, it is the application waiting to be given one.
    var documentName: String { current?.name ?? "Driftbox" }
    var undoManager: UndoManager? {
      didSet { refreshUndo() }
    }
    /// The manager's own state, mirrored here. A menu built straight from `UndoManager` would be
    /// as stale as whenever something else happened to redraw it: `canUndo` is not observable.
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"

    private let audio = AVAudioEngine()
    private var unit: DriftboxAudioUnit?
    /// Where the sound goes out, kept there as devices come and go.
    private var route: AudioRoute?
    /// The device chosen to play through, by its UID; nil for whatever the system plays through.
    var outputDevice: String? {
      didSet { route?.chosen = outputDevice }
    }
    /// Every device there is to play through, kept up to date as they come and go.
    private(set) var outputs: [AudioOutput] = []
    /// The one the sound is going out of: the chosen one while it is there, the system's while
    /// it is not.
    private(set) var playingThrough: AudioOutput?
    /// The device the system plays through, which is what "the system's" means today.
    private(set) var systemOutput: AudioOutput?
    /// Why nothing can be heard, while nothing can. Apart from `error`, because it goes away on
    /// its own when a device comes back.
    private(set) var outputError: String?
    /// An engine of the player's own, for a player made without an audio unit to hold one.
    private var standalone: EngineHost?
    private var clock: Timer?

    /// The engine behind the transport, whichever way the player was made. Everything the
    /// interface reads comes from here, and nothing it reads is the audio device's.
    private var host: EngineHost? { unit?.host ?? standalone }

    // MARK: MIDI

    private var midi: MIDIInput?
    /// Whether anything arriving on a MIDI cable is played at all — the switch over the whole of
    /// it, above the choice of sources below.
    var listensToMIDI = true
    /// Sources to hear nothing from, by name: a machine that streams notes at a sequencer it was
    /// not meant to be driving can be silenced without unplugging it, and without silencing the
    /// keyboard that is meant to.
    var ignoredMIDISources: Set<String> = [] {
      didSet { midi?.ignoring = ignoredMIDISources }
    }
    /// Every source there is, kept up to date as devices come and go, so a list of them in
    /// Settings changes while it is open rather than the next time it is.
    private(set) var midiSources: [String] = []
    /// Follow an external MIDI clock: tempo, start, stop and position. Off unless asked for,
    /// because plenty of gear streams clock the moment it is plugged in, and a sequencer that
    /// handed its transport to whatever is on the cable would be taking an instrument away.
    var followsClock = false {
      didSet {
        // Following and sending are kept apart. The loop that first made them exclusive — our
        // own ticks coming back in through our own source — cannot happen any more, because the
        // input no longer hears that source. What is left is a loop through somebody's MIDI thru,
        // which is rarer, and relaying a master clock on to other gear, which would be worth
        // having; which of those wins is a decision about the instrument and has not been made.
        if followsClock, sendsClock { sendsClock = false }
        // Letting go of the clock means the song's own tempo again, in the engine as well as here.
        guard !followsClock, followedBPM != nil else { return }
        let step = currentStep
        followedBPM = nil
        if let song { load(song) }
        seek(toStep: step)
        if isPlaying { startEngine() }
      }
    }
    private(set) var followedBPM: Double? {
      didSet { retime() }
    }
    private var follower = ClockFollower()
    /// The song's own tempo, which following leaves alone: the followed tempo is not written in.
    private var songBPM: Double { song?.bpm ?? 120 }

    // MARK: Clock out

    private var clockOut: MIDIOutput?
    /// Send MIDI clock out: start, or position and continue when the transport is not at the top;
    /// six ticks a sixteenth while it runs; stop. Off unless asked for, because a clock on the
    /// cable puts everything listening to it under this machine's transport, which is a decision
    /// about the studio and not one a sequencer should make on its own.
    var sendsClock = false {
      didSet {
        guard sendsClock != oldValue else { return }
        if sendsClock {
          followsClock = false
        } else {
          deliver(cursor.stop(at: MIDIOutput.now()))
        }
      }
    }
    /// Every destination there is, as of the last tick.
    private(set) var clockDestinations: [String] = []
    var clockDestination = MIDIOutput.Destination.virtual {
      didSet {
        guard clockDestination != oldValue else { return }
        // Ticks queued at the destination being left would go on arriving after we had stopped
        // talking to it, so it is stopped properly and the new one is located from scratch.
        deliver(cursor.stop(at: MIDIOutput.now()), to: oldValue)
      }
    }

    /// Which step's ticks go out next, and when.
    private var cursor = ClockCursor()

    /// Where the song that is open is written down, so the next launch can open it again. The
    /// application's own preferences; nothing at all for a player built without a device, so a
    /// test that opens files by the dozen does not rewrite what the app will open next.
    var memory: UserDefaults?

    public init() {
      memory = .standard
      AUAudioUnit.registerSubclass(
        DriftboxAudioUnit.self, as: DriftboxAudioUnit.componentDescription, name: "Driftbox", version: 1)
      AVAudioUnit.instantiate(with: DriftboxAudioUnit.componentDescription, options: []) {
        [self] made, failure in
        Task { @MainActor in
          guard let made, let driftbox = made.auAudioUnit as? DriftboxAudioUnit else {
            error = failure.map { "\($0)" } ?? "the audio unit could not be made"
            return
          }
          audio.attach(made)
          audio.connect(made, to: audio.mainMixerNode, format: made.outputFormat(forBus: 0))
          unit = driftbox
          if let song { driftbox.load(song) }
          // The route starts the engine, on the device chosen, and starts it again whenever a
          // change of device stops it.
          let route = AudioRoute(engine: audio, chosen: outputDevice)
          route.onChange = { [weak self, weak route] in
            guard let self, let route else { return }
            outputs = route.outputs
            playingThrough = route.current
            systemOutput = route.systemDefault
            outputError = route.error
          }
          route.onChange?()
          self.route = route
        }
      }
      clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
      let midi = MIDIInput()
      midi.ignoring = ignoredMIDISources
      midi.onNote = { [weak self] note, velocity in
        Task { @MainActor in self?.midiNote(note, velocity: velocity) }
      }
      midi.onClock = { [weak self] message, time in
        Task { @MainActor in self?.midiClock(message, at: time) }
      }
      midi.onSourcesChange = { [weak self] names in
        Task { @MainActor in self?.midiSources = names }
      }
      midiSources = midi.sources
      self.midi = midi
      let clockOut = MIDIOutput()
      // The input never hears the app's own output: it would only ever be the app's own clock
      // coming back round.
      midi.hiding = clockOut.sourceID.map { [$0] } ?? []
      self.clockOut = clockOut
    }

    /// A player on an engine of its own: no audio device, no MIDI ports and no timer behind the
    /// tick. It is everything the interface does and none of the hardware it usually does it to,
    /// which is the only shape a test can make one in; whoever builds it renders `host` by hand
    /// and calls `tick` when it wants the interface to catch up.
    init(host: EngineHost) {
      standalone = host
    }

    /// Both ends of the engine, which the audio unit and a standalone host answer differently: the
    /// unit holds what it is given until the device has made it a host, and a player built on one
    /// of its own has it already.
    private func load(_ song: Song) {
      if let unit { unit.load(song) } else { standalone?.load(song) }
    }

    private func send(_ command: Command) {
      if let unit { unit.send(command) } else { standalone?.send(command) }
    }

    /// The web app's keys: notes from 33 (A1) play 303 A across two octaves; below that, the drum
    /// voices the grid shows, from note 21 up. A note's velocity past 0.8 is an accent.
    private func midiNote(_ note: Int, velocity: Double) {
      guard listensToMIDI, velocity > 0 else { return }
      let accent = velocity >= 0.8
      if note >= 33 {
        playNote(semitone: note - 33 - 12, accent: accent)
      } else if note >= 21 {
        strike(index: note - 21, accent: accent)
      }
    }

    private func midiClock(_ message: ClockMessage, at time: Double) {
      guard listensToMIDI, followsClock, song != nil else { return }
      let local = LocalClockState(
        bpm: followedBPM ?? songBPM,
        ticks: Double(songFrame) / sampleRate * (followedBPM ?? songBPM) * 24 / 60,
        time: time)
      let command = followClock(message, at: time, follower: &follower, local: local)
      if let bpm = command.bpm { follow(bpm: bpm) }
      switch command.transport {
      case .start:
        send(.seek(songFrame: 0))
        startEngine()
      case .resume:
        if let step = command.step { seek(toStep: step) }
        startEngine()
      case .stop:
        send(.stop)
      case nil:
        break
      }
    }

    /// Run the song at `bpm` without writing it in: the compiled song is remade at that tempo and
    /// taken up at the same step.
    private func follow(bpm: Double) {
      guard let song, abs((followedBPM ?? songBPM) - bpm) >= 0.05 else { return }
      let step = currentStep
      followedBPM = bpm
      var retimed = song
      retimed.bpm = bpm
      load(retimed)
      seek(toStep: step)
      if isPlaying { startEngine() }
    }

    /// The transport's position in sixteenths from the top.
    var currentStep: Int {
      timeline.step(at: Double(songFrame) / sampleRate) ?? 0
    }

    func seek(toStep step: Int) {
      guard !timeline.times.isEmpty else { return }
      let index = min(max(0, step), timeline.times.count - 1)
      send(.seek(songFrame: Int(timeline.times[index] * sampleRate)))
    }

    /// Thirty times a second. Everything the views read is written only when it has changed:
    /// an observable that is set every tick has every view that reads it rebuilt every tick,
    /// which was most of the main thread.
    func tick() {
      guard let host else { return }
      songFrame = max(0, host.songFrame.load(ordering: .relaxed))
      let playing = host.playing.load(ordering: .relaxed)
      if isPlaying != playing { isPlaying = playing }
      let counting = host.countingIn.load(ordering: .relaxed)
      if countingIn != counting { countingIn = counting }
      host.collect()
      engineFrame = host.engineFrame.load(ordering: .relaxed)
      while let event = host.nextEvent() {
        if event.kind == .hit { lastHits[event.voice] = event.frame }
        pendingEvents.append(event)
      }
      if pendingEvents.count > 512 { pendingEvents.removeFirst(pendingEvents.count - 512) }
      let lit = Set(lastHits.filter { engineFrame - $0.value < 4800 }.keys)
      if struck != lit { struck = lit }
      updatePosition()
      driveClock()
    }

    /// Write the next fifth of a second of clock, and start or stop it with the transport.
    ///
    /// Called from the tick, after `songFrame` has been read, because everything here hangs off it:
    /// the ticks are placed on the host clock ahead of the audio and played by the MIDI server at
    /// the stamped moment, rather than sent thirty times a second in whatever bursts the main
    /// thread allows. Where the cursor has got to is what keeps that honest, and it is the cursor
    /// that decides; this only finds the port and the moment, and puts what comes back on it.
    private func driveClock() {
      guard let out = clockOut else { return }
      if clockDestinations != out.destinations { clockDestinations = out.destinations }
      let now = MIDIOutput.now()
      // Anything that leaves the transport without a song to run is a stop as much as the button
      // is: what is listening should not be left ticking through a song nobody is playing.
      // A count-in is not the song yet: what is listening starts with it, not with the clicks.
      guard sendsClock, song != nil, !timeline.times.isEmpty, isPlaying, !countingIn else {
        deliver(cursor.idle(at: now))
        return
      }
      // Where the song is at the speakers, not at the render block: the engine has rendered past
      // what is being heard by the device's latency, and the clock belongs with the music.
      let sounding = MIDIOutput.time(now, after: audio.outputNode.presentationLatency)
      deliver(
        cursor.advance(
          timeline: timeline, songTime: Double(songFrame) / sampleRate, now: now, sounding: sounding))
    }

    /// What the cursor decided, onto a port. The destination is the one in force unless the clock
    /// is being taken off the one it was just moved away from.
    private func deliver(_ messages: [ClockCursor.Out], to destination: MIDIOutput.Destination? = nil) {
      guard let out = clockOut, !messages.isEmpty else { return }
      let target = destination ?? clockDestination
      for message in messages {
        switch message {
        case .flush: out.flush(target)
        case .send(let clock, let time): out.send(clock.bytes, to: target, at: time)
        }
      }
    }

    func open(_ entry: CatalogueEntry) {
      guard let loaded = Catalogue.song(entry.id) else { return }
      take(loaded, as: entry, from: nil)
      startEngine()
    }

    /// A song document from disk, in the web app's format.
    func open(file url: URL) {
      guard take(file: url) else {
        error = "\(url.lastPathComponent) is not a song"
        return
      }
      startEngine()
    }

    /// Read a document and make it the song, without starting anything. False if it is not one.
    @discardableResult
    private func take(file url: URL) -> Bool {
      guard let data = try? Data(contentsOf: url),
        let loaded = SongCodec.decode(String(decoding: data, as: UTF8.self))
      else { return false }
      // A document's name is its file's, stripped of both halves of `.song.json`.
      var name = url.deletingPathExtension().lastPathComponent
      if name.hasSuffix(".song") { name.removeLast(5) }
      let entry = CatalogueEntry(id: url.path, name: name, blurb: "", visual: loaded.visual ?? "")
      take(loaded, as: entry, from: url)
      return true
    }

    // MARK: - Remembered between launches

    /// The song that was open when the app last quit, as it was last saved — and stopped at the
    /// top, because sound nobody asked for is the one thing not worth restoring. A document comes
    /// back through a bookmark rather than a path, so one renamed or moved in the Finder since is
    /// still found; one that has gone is forgotten rather than reported.
    public func restore() {
      // Read before the song is opened, since opening one forgets it.
      let pattern = memory?.string(forKey: Defaults.lastPattern)
      restoreSong()
      if let pattern, song?.pattern(id: pattern) != nil { editing = pattern }
    }

    private func restoreSong() {
      guard let memory else { return }
      if let bookmark = memory.data(forKey: Defaults.lastFile) {
        var stale = false
        if let url = try? URL(
          resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale
        ),
          take(file: url)
        {
          return
        }
        memory.removeObject(forKey: Defaults.lastFile)
      } else if let id = memory.string(forKey: Defaults.lastSong),
        let entry = entries.first(where: { $0.id == id }), let loaded = Catalogue.song(id)
      {
        take(loaded, as: entry, from: nil)
      }
    }

    /// Write down what is open. A catalogue song by its id, a document by a bookmark, and a new
    /// song not at all: it has nowhere to come back from, and quitting has already asked whether
    /// to save it.
    private func remember(_ entry: CatalogueEntry, at url: URL?) {
      guard let memory else { return }
      memory.removeObject(forKey: Defaults.lastSong)
      memory.removeObject(forKey: Defaults.lastFile)
      if let url {
        memory.set(try? url.bookmarkData(), forKey: Defaults.lastFile)
      } else if !entry.id.isEmpty {
        memory.set(entry.id, forKey: Defaults.lastSong)
      }
    }

    /// An empty song to start from. It arrives with the 909's core voices and a 303 line already
    /// laid out, because the grid draws the lanes a pattern has and a song with none is a wall.
    func new() {
      var pattern = DriftboxSeq.Pattern(id: "pattern-1", name: "Pattern 1", length: 16)
      for voiceId in ["909.bd", "909.sd", "909.cp", "909.ch", "909.oh"] {
        pattern.tracks[voiceId] = [StepValue](repeating: .off, count: 16)
      }
      pattern.bass["303.a"] = [BassStep](repeating: .rest, count: 16)
      var fresh = Song(patterns: [pattern])
      fresh.chain = [ChainStep(pattern: pattern.id)]
      let entry = CatalogueEntry(id: "", name: "Untitled", blurb: "", visual: "")
      take(fresh, as: entry, from: nil)
    }

    /// Everything that puts a different song in the window: the undo history is the old song's and
    /// goes with it, and what arrives is unedited whatever the thing it replaced was.
    private func take(_ loaded: Song, as entry: CatalogueEntry, from url: URL?) {
      current = entry
      fileURL = url
      editing = nil
      loop = nil
      remember(entry, at: url)
      undoManager?.removeAllActions()
      refreshUndo()
      song = loaded
      saved = loaded
      isEdited = false
      load(loaded)
    }

    /// Write the song back where it came from. Nothing without a file: that is Save As's question.
    func save() {
      guard let fileURL else { return }
      save(to: fileURL)
    }

    func save(to url: URL) {
      guard let song else { return }
      do {
        try Data(SongCodec.encode(song).utf8).write(to: url)
        fileURL = url
        saved = song
        isEdited = false
        // Saving under a new name renames the window with it, as a document's title follows its
        // file rather than whatever it was called when it was opened.
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".song") { name.removeLast(5) }
        current = CatalogueEntry(
          id: url.path, name: name, blurb: current?.blurb ?? "", visual: current?.visual ?? "")
        // Saved somewhere new, it comes back from there.
        if let current { remember(current, at: url) }
      } catch {
        self.error = "\(error)"
      }
    }

    /// Jump to the start of a bar of the arrangement.
    func seek(toBar bar: Int) {
      guard song != nil else { return }
      send(.seek(songFrame: Int(timeline.start(ofBar: bar) * sampleRate)))
    }

    /// Where each entry of the chain begins, in bars. A song with no chain is one pattern playing
    /// for ever, which is a single section.
    var sectionBars: [Int] {
      guard let song, !song.chain.isEmpty else { return [0] }
      var bar = 0
      return song.chain.map { entry in
        defer { bar += max(1, entry.repeat) }
        return bar
      }
    }

    /// Move the transport a chain entry at a time, wrapping at both ends because the chain does.
    func skip(sections delta: Int) {
      let starts = sectionBars
      guard song != nil, !starts.isEmpty else { return }
      let bar = position?.bar ?? 0
      let here = starts.lastIndex { $0 <= bar } ?? 0
      let next = (here + delta % starts.count + starts.count) % starts.count
      seek(toBar: starts[next])
    }

    /// Play because someone asked to: from a stop, that counts in first if a count-in is set.
    func play() {
      cursor.resume()
      send(.start)
    }

    // MARK: Loop, metronome, count-in

    /// A click on every beat while the song plays.
    var metronome = false {
      didSet { if metronome != oldValue { send(.metronome(metronome)) } }
    }

    /// A bar of clicks before the song moves, when play is pressed from a stop.
    var countsIn = false {
      didSet { if countsIn != oldValue { send(.countIn(bars: countsIn ? 1 : 0)) } }
    }

    /// Whether the song is waiting on its count-in.
    private(set) var countingIn = false

    /// A run of whole bars to play round and round.
    struct LoopRange: Equatable {
      var start: Int
      var bars: Int
      var end: Int { start + bars }
      func contains(bar: Int) -> Bool { bar >= start && bar < end }
    }

    /// The bars being looped. The engine goes round at the loop's end on its exact frame, and
    /// holds the loop in bars, so an edit — which moves every frame — leaves it where it was.
    var loop: LoopRange? {
      didSet {
        guard loop != oldValue else { return }
        send(.loop(startBar: loop?.start ?? 0, bars: loop?.bars ?? 0))
      }
    }

    /// Loop the section from `start` for `bars`, or stop looping it if it already is.
    func toggleLoop(start: Int, bars: Int) {
      let range = LoopRange(start: max(0, start), bars: max(1, bars))
      loop = loop == range ? nil : range
    }

    /// Stretch the loop to take in the section from `start` for `bars`, whichever side it is on.
    func extendLoop(toStart start: Int, bars: Int) {
      guard let current = loop else { return toggleLoop(start: start, bars: bars) }
      let from = min(current.start, start)
      let to = max(current.end, start + max(1, bars))
      loop = LoopRange(start: from, bars: to - from)
    }

    func stop() {
      send(.stop)
      // Here rather than at the next tick: a stop a thirtieth of a second late is a stop that
      // arrives behind ticks the engine is never going to play.
      deliver(cursor.halt(at: MIDIOutput.now()))
    }

    /// Everything that starts the engine goes through here, so that a stop the transport has not
    /// caught up with yet cannot leave the clock out held down.
    private func startEngine() {
      cursor.resume()
      send(.play)
    }

    func toggle() {
      isPlaying ? stop() : play()
    }

    /// The voices the song uses, in the order the grid shows them.
    var usedVoices: [Voice] {
      guard let pattern = shownPattern else { return [] }
      return allVoices.filter { pattern.tracks[$0.id] != nil }
    }

    /// Strike the `index`th voice of the grid, now, with the song's knobs for it.
    func strike(index: Int, accent: Bool) {
      guard let host, let song, usedVoices.indices.contains(index) else { return }
      let voice = usedVoices[index]
      let group =
        voice.choke.flatMap { ["808.hats", "909.hats"].firstIndex(of: $0) }.map { UInt8($0 + 1) } ?? 0
      let hit = host.preparer.prepare(
        voice.build(song.kit.params[voice.id] ?? VoiceParams(), accent: accent ? 1 : 0.55), voiceId: voice.id,
        at: 0,
        sends: song.kit.sends[voice.id] ?? SendLevels(), chokeGroup: group)
      send(.strike(hit))
    }

    /// Play a note on 303 A, now, with the song's panel for it.
    func playNote(semitone: Int, accent: Bool) {
      guard let song else { return }
      let params = song.kit.bass["303.a"] ?? BassParams()
      let step = BassStep(note: Double(max(0, min(24, semitone + 12))), accent: accent)
      guard
        let note = bassNote(
          params: params, step: step, previous: .rest, stepSeconds: secondsPerStep(bpm: song.bpm))
      else { return }
      send(.note(line: 0, note))
    }

    func pad(x: Double, y: Double) {
      padTouch = SIMD2(Float(x), Float(y))
      send(.pad(x: x, y: y))
    }

    func padRelease() {
      padTouch = nil
      send(.padRelease)
    }

    /// What the engine has reported since the scene last asked.
    func takeEvents() -> [EngineEvent] {
      defer { pendingEvents.removeAll() }
      return pendingEvents
    }

    /// The tempo the song is running at: the followed one, or its own.
    var tempo: Double { followedBPM ?? songBPM }

    /// Where the song is in quarter notes, read straight from the engine for the scene's frame
    /// rather than from the last tick, so it is smooth at the display's rate.
    func scoreBeat() -> Double? {
      guard let host, !timeline.times.isEmpty else { return nil }
      let frame = host.songFrame.load(ordering: .relaxed)
      guard frame >= 0 else { return nil }
      let time = Double(frame) / sampleRate
      guard let index = timeline.step(at: time) else { return 0 }
      let start = timeline.times[index]
      let end = index + 1 < timeline.times.count ? timeline.times[index + 1] : timeline.end
      let fraction = end > start ? min(1, (time - start) / (end - start)) : 0
      return (Double(index) + fraction) / 4
    }

    /// The mix's bass, mids and highs for the scene, from the last two thousand frames it heard.
    private let analyser = Analyser()
    private var monitor = [Float](repeating: 0, count: Analyser.size)

    /// The spectrum is only worked out again when new audio has arrived. That is what Web
    /// Audio's analyser does — two reads inside one render quantum get the same answer — and it
    /// matters because the smoothing is applied per analysis: a display faster than the audio
    /// blocks, or two views asking in one frame, would otherwise make the bands fall faster
    /// than they do on the web.
    func analyse() -> Analyser? {
      guard let host else { return nil }
      let written = host.mixWritten
      if written == analysedAt { return analyser }
      analysedAt = written
      monitor.withUnsafeMutableBufferPointer { buffer in
        host.recentMix(Analyser.size, into: buffer.baseAddress!)
        analyser.update(UnsafeBufferPointer(buffer))
      }
      return analyser
    }
    private var analysedAt = -1

    /// The loudest sample of the last audio block, each side.
    var peaks: (left: Float, right: Float) {
      guard let host else { return (0, 0) }
      return (
        Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
        Float(bitPattern: host.peakRight.load(ordering: .relaxed))
      )
    }

    /// Which voice's panel is showing.
    var selectedVoice: String?
    /// A pattern chosen to edit, or nil to follow the transport. Remembered with the song, so the
    /// next launch opens on the pattern that was being worked on rather than the first one.
    var editing: String? {
      didSet {
        guard editing != oldValue, let memory else { return }
        if let editing {
          memory.set(editing, forKey: Defaults.lastPattern)
        } else {
          memory.removeObject(forKey: Defaults.lastPattern)
        }
      }
    }

    /// Clicking a 909 step marks a flam rather than cycling the step.
    var flamMode = false

    /// A lane or line copied, to paste into another. The app's own, not the pasteboard's: nothing
    /// outside Driftbox could do anything with it.
    enum LaneClipboard {
      case drum(DrumLaneClipboard)
      case bass(BassLineClipboard)
    }
    private(set) var laneClipboard: LaneClipboard?

    /// Change the pattern the grid shows, undoably, under `name`.
    func editShown(_ name: String, _ change: (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      guard let id = shownPattern?.id else { return }
      editPattern(id, name, change)
    }

    func editPattern(_ id: String, _ name: String, _ change: (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
      edit(name) { song in
        guard let at = song.patterns.firstIndex(where: { $0.id == id }) else { return }
        song.patterns[at] = change(song.patterns[at])
      }
    }

    func copyLane(_ voiceId: String) {
      guard let pattern = shownPattern else { return }
      laneClipboard =
        voiceId.hasPrefix("303.")
        ? .bass(pattern.copyingBassLine(voiceId)) : .drum(pattern.copyingDrumLane(voiceId))
    }

    func cutLane(_ voiceId: String) {
      copyLane(voiceId)
      editShown(voiceId.hasPrefix("303.") ? "Cut Line" : "Cut Lane") {
        voiceId.hasPrefix("303.") ? $0.clearingBassLine(voiceId) : $0.clearingTrack(voiceId)
      }
    }

    /// Whether what is on the clipboard can go into `voiceId`: a drum lane into a drum lane, a
    /// line into a line.
    func canPasteLane(into voiceId: String) -> Bool {
      switch laneClipboard {
      case .drum: !voiceId.hasPrefix("303.")
      case .bass: voiceId.hasPrefix("303.")
      case nil: false
      }
    }

    func pasteLane(into voiceId: String) {
      switch laneClipboard {
      case .drum(let lane) where !voiceId.hasPrefix("303."):
        editShown("Paste Lane") { $0.pastingDrumLane(voiceId, lane) }
      case .bass(let line) where voiceId.hasPrefix("303."):
        editShown("Paste Line") { $0.pastingBassLine(voiceId, line) }
      default:
        break
      }
    }

    /// The pattern the grid shows.
    var shownPattern: DriftboxSeq.Pattern? {
      if let editing, let chosen = song?.pattern(id: editing) { return chosen }
      return position?.pattern ?? song?.patterns.first
    }

    /// Change the song and have the engine take it up where it is, without stopping. Undoable
    /// under `name`, which is what the Edit menu offers to undo — "Undo Set Step", not "Undo".
    func edit(_ name: String = "Edit", _ change: (inout Song) -> Void) {
      guard let before = song else { return }
      var edited = before
      change(&edited)
      replace(with: edited, undoing: before, name: name)
    }

    /// Undo and redo go through here rather than straight at the manager, so that what the menu
    /// shows is read back afterwards: the manager says nothing when its stack moves.
    func undo() {
      undoManager?.undo()
      refreshUndo()
    }

    func redo() {
      undoManager?.redo()
      refreshUndo()
    }

    private func refreshUndo() {
      let undoable = undoManager?.canUndo ?? false
      let redoable = undoManager?.canRedo ?? false
      if canUndo != undoable { canUndo = undoable }
      if canRedo != redoable { canRedo = redoable }
      let undone = undoManager?.undoActionName ?? ""
      let redone = undoManager?.redoActionName ?? ""
      let undo = undone.isEmpty ? "Undo" : "Undo \(undone)"
      let redo = redone.isEmpty ? "Redo" : "Redo \(redone)"
      if undoTitle != undo { undoTitle = undo }
      if redoTitle != redo { redoTitle = redo }
    }

    private func replace(with edited: Song, undoing before: Song, name: String) {
      song = edited
      isEdited = edited != saved
      undoManager?.registerUndo(withTarget: self) { player in
        MainActor.assumeIsolated { player.replace(with: before, undoing: edited, name: name) }
      }
      undoManager?.setActionName(name)
      refreshUndo()
      let position = songFrame
      load(edited)
      send(.seek(songFrame: position))
      if isPlaying { startEngine() }
    }

    // MARK: - Where the song is

    struct Position: Equatable {
      /// Which bar of the arrangement, and which step in it.
      var bar: Int
      var step: Int
      var pattern: DriftboxSeq.Pattern?

      /// The same place in the same pattern; the pattern's contents are the song's business.
      static func == (a: Position, b: Position) -> Bool {
        a.bar == b.bar && a.step == b.step && a.pattern?.id == b.pattern?.id
      }
    }

    /// The step the transport is on. Written when the step changes, and when the song does.
    private(set) var position: Position?

    private func updatePosition(force: Bool = false) {
      var next: Position?
      if let song, let index = timeline.step(at: Double(songFrame) / sampleRate) {
        let bar = timeline.bars[index]
        next = Position(bar: bar, step: timeline.indices[index], pattern: song.pattern(forBar: bar))
      }
      if force || next != position { position = next }
    }

    private var timeline = Timeline()

    private func retime() {
      guard let song else {
        timeline = Timeline()
        updatePosition(force: true)
        return
      }
      var running = song
      if let bpm = followedBPM { running.bpm = bpm }
      timeline = Timeline(song: running)
      updatePosition(force: true)
    }
  }
#endif
