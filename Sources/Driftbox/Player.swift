#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
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
  final class Player {
    private(set) var entries = Catalogue.entries()
    private(set) var current: CatalogueEntry?
    var song: Song?
    private(set) var isPlaying = false
    /// Where the transport is, in the song's own frames.
    private(set) var songFrame = 0
    private(set) var sampleRate = 48000.0
    private(set) var error: String?
    /// The last voice struck, by index into `allVoices`, and when: for anything that wants to
    /// flash. Taken from the engine's events ring thirty times a second.
    private(set) var lastHits: [Int: Int] = [:]
    /// The engine's own clock, which the events are stamped in.
    private(set) var engineFrame = 0
    /// Events since the scene last drew, kept for it here; the grid's flashes read `lastHits`.
    private var pendingEvents: [EngineEvent] = []
    /// Where the pad is being touched, for the scene's cursor.
    var padTouch: SIMD2<Float>?
    /// Whether the visuals pane is showing.
    var showsVisuals = true
    /// Where the song came from, if a file; where Save goes.
    var fileURL: URL?
    var undoManager: UndoManager?

    private let audio = AVAudioEngine()
    private var unit: DriftboxAudioUnit?
    private var clock: Timer?

    // MARK: MIDI

    private var midi: MIDIInput?
    /// Follow an external MIDI clock: tempo, start, stop and position. Off unless asked for,
    /// because plenty of gear streams clock the moment it is plugged in, and a sequencer that
    /// handed its transport to whatever is on the cable would be taking an instrument away.
    var followsClock = false {
      didSet { if !followsClock { followedBPM = nil } }
    }
    private(set) var followedBPM: Double?
    var midiSources: [String] { midi?.sources ?? [] }
    private var follower = ClockFollower()
    /// The song's own tempo, which following leaves alone: the followed tempo is not written in.
    private var songBPM: Double { song?.bpm ?? 120 }

    init() {
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
          sampleRate = made.outputFormat(forBus: 0).sampleRate
          unit = driftbox
          do {
            try audio.start()
          } catch {
            self.error = "\(error)"
          }
          if let song { driftbox.load(song) }
        }
      }
      clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
      let midi = MIDIInput()
      midi.onNote = { [weak self] note, velocity in
        Task { @MainActor in self?.midiNote(note, velocity: velocity) }
      }
      midi.onClock = { [weak self] message, time in
        Task { @MainActor in self?.midiClock(message, at: time) }
      }
      self.midi = midi
    }

    /// The web app's keys: notes from 33 (A1) play 303 A across two octaves; below that, the drum
    /// voices the grid shows, from note 21 up. A note's velocity past 0.8 is an accent.
    private func midiNote(_ note: Int, velocity: Double) {
      guard velocity > 0 else { return }
      let accent = velocity >= 0.8
      if note >= 33 {
        playNote(semitone: note - 33 - 12, accent: accent)
      } else if note >= 21 {
        strike(index: note - 21, accent: accent)
      }
    }

    private func midiClock(_ message: ClockMessage, at time: Double) {
      guard followsClock, let song else { return }
      let local = LocalClockState(
        bpm: followedBPM ?? songBPM,
        ticks: Double(songFrame) / sampleRate * (followedBPM ?? songBPM) * 24 / 60,
        time: time)
      let command = followClock(message, at: time, follower: &follower, local: local)
      if let bpm = command.bpm { follow(bpm: bpm) }
      switch command.transport {
      case .start:
        unit?.send(.seek(songFrame: 0))
        unit?.send(.play)
      case .resume:
        if let step = command.step { seek(toStep: step) }
        unit?.send(.play)
      case .stop:
        unit?.send(.stop)
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
      unit?.load(retimed)
      seek(toStep: step)
      if isPlaying { unit?.send(.play) }
    }

    /// The transport's position in sixteenths from the top.
    var currentStep: Int {
      guard let position, let song else { return 0 }
      var steps = 0
      for bar in 0..<position.bar { steps += song.barLength(forBar: bar) }
      return steps + position.step
    }

    func seek(toStep step: Int) {
      guard let song else { return }
      var retimed = song
      if let bpm = followedBPM { retimed.bpm = bpm }
      let plan = retimed.plan(bars: retimed.chain.isEmpty ? 1 : retimed.bars)
      guard !plan.isEmpty else { return }
      let index = min(max(0, step), plan.count - 1)
      unit?.send(.seek(songFrame: Int(plan[index].time * sampleRate)))
    }

    private func tick() {
      guard let host = unit?.host else { return }
      songFrame = max(0, host.songFrame.load(ordering: .relaxed))
      isPlaying = host.playing.load(ordering: .relaxed)
      host.collect()
      engineFrame = host.engineFrame.load(ordering: .relaxed)
      while let event = host.nextEvent() {
        if event.kind == .hit { lastHits[event.voice] = event.frame }
        pendingEvents.append(event)
      }
      if pendingEvents.count > 512 { pendingEvents.removeFirst(pendingEvents.count - 512) }
    }

    func open(_ entry: CatalogueEntry) {
      guard let loaded = Catalogue.song(entry.id) else { return }
      current = entry
      fileURL = nil
      undoManager?.removeAllActions()
      song = loaded
      unit?.load(loaded)
      unit?.send(.play)
    }

    /// A song document from disk, in the web app's format.
    func open(file url: URL) {
      guard let data = try? Data(contentsOf: url),
        let loaded = SongCodec.decode(String(decoding: data, as: UTF8.self))
      else {
        error = "\(url.lastPathComponent) is not a song"
        return
      }
      current = CatalogueEntry(
        id: url.path, name: url.deletingPathExtension().lastPathComponent, blurb: "",
        visual: loaded.visual ?? "")
      fileURL = url
      undoManager?.removeAllActions()
      song = loaded
      unit?.load(loaded)
      unit?.send(.play)
    }

    func save(to url: URL) {
      guard let song else { return }
      do {
        try Data(SongCodec.encode(song).utf8).write(to: url)
        fileURL = url
      } catch {
        self.error = "\(error)"
      }
    }

    /// Jump to the start of a bar of the arrangement.
    func seek(toBar bar: Int) {
      guard let song else { return }
      let plan = song.plan(bars: min(bar, song.bars))
      let time = plan.last.map { $0.time + $0.stepSeconds } ?? 0
      unit?.send(.seek(songFrame: bar == 0 ? 0 : Int(time * sampleRate)))
    }

    func play() {
      unit?.send(.play)
    }

    func stop() {
      unit?.send(.stop)
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
      guard let host = unit?.host, let song, usedVoices.indices.contains(index) else { return }
      let voice = usedVoices[index]
      let group =
        voice.choke.flatMap { ["808.hats", "909.hats"].firstIndex(of: $0) }.map { UInt8($0 + 1) } ?? 0
      let hit = host.preparer.prepare(
        voice.build(song.kit.params[voice.id] ?? VoiceParams(), accent: accent ? 1 : 0.55), voiceId: voice.id,
        at: 0,
        sends: song.kit.sends[voice.id] ?? SendLevels(), chokeGroup: group)
      unit?.send(.strike(hit))
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
      unit?.send(.note(line: 0, note))
    }

    func pad(x: Double, y: Double) {
      padTouch = SIMD2(Float(x), Float(y))
      unit?.send(.pad(x: x, y: y))
    }

    func padRelease() {
      padTouch = nil
      unit?.send(.padRelease)
    }

    /// What the engine has reported since the scene last asked.
    func takeEvents() -> [EngineEvent] {
      defer { pendingEvents.removeAll() }
      return pendingEvents
    }

    /// The loudest sample of the last audio block, each side.
    var peaks: (left: Float, right: Float) {
      guard let host = unit?.host else { return (0, 0) }
      return (
        Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
        Float(bitPattern: host.peakRight.load(ordering: .relaxed))
      )
    }

    /// Which voice's panel is showing.
    var selectedVoice: String?
    /// A pattern chosen to edit, or nil to follow the transport.
    var editing: String?

    /// The pattern the grid shows.
    var shownPattern: DriftboxSeq.Pattern? {
      if let editing, let chosen = song?.pattern(id: editing) { return chosen }
      return position?.pattern ?? song?.patterns.first
    }

    /// Change the song and have the engine take it up where it is, without stopping. Undoable.
    func edit(_ change: (inout Song) -> Void) {
      guard let before = song else { return }
      var edited = before
      change(&edited)
      replace(with: edited, undoing: before)
    }

    private func replace(with edited: Song, undoing before: Song) {
      song = edited
      undoManager?.registerUndo(withTarget: self) { player in
        MainActor.assumeIsolated { player.replace(with: before, undoing: edited) }
      }
      let position = songFrame
      unit?.load(edited)
      unit?.send(.seek(songFrame: position))
      if isPlaying { unit?.send(.play) }
    }

    // MARK: - Where the song is

    /// The step the transport is on: which bar of the arrangement, and which step in it.
    var position: (bar: Int, step: Int, pattern: DriftboxSeq.Pattern?)? {
      guard let song else { return nil }
      let plan = song.plan(bars: song.chain.isEmpty ? 1 : song.bars)
      let time = Double(songFrame) / sampleRate
      var index = 0
      for (candidate, step) in plan.enumerated() where step.time <= time { index = candidate }
      guard index < plan.count else { return nil }
      var bar = 0
      var counted = 0
      while bar < song.bars, counted + song.barLength(forBar: bar) <= index {
        counted += song.barLength(forBar: bar)
        bar += 1
      }
      return (bar, index - counted, song.pattern(forBar: bar))
    }
  }
#endif
