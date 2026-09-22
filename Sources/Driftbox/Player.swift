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
  final class Player {
    private(set) var entries = Catalogue.entries()
    private(set) var current: CatalogueEntry?
    var song: Song? {
      didSet { retime() }
    }
    private(set) var isPlaying = false
    /// Where the transport is, in the song's own frames.
    private(set) var songFrame = 0
    private(set) var sampleRate = 48000.0
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
      didSet {
        // Letting go of the clock means the song's own tempo again, in the engine as well as here.
        guard !followsClock, followedBPM != nil else { return }
        let step = currentStep
        followedBPM = nil
        if let song { unit?.load(song) }
        seek(toStep: step)
        if isPlaying { unit?.send(.play) }
      }
    }
    private(set) var followedBPM: Double? {
      didSet { retime() }
    }
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
      guard followsClock, song != nil else { return }
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
      timeline.step(at: Double(songFrame) / sampleRate) ?? 0
    }

    func seek(toStep step: Int) {
      guard !timeline.times.isEmpty else { return }
      let index = min(max(0, step), timeline.times.count - 1)
      unit?.send(.seek(songFrame: Int(timeline.times[index] * sampleRate)))
    }

    /// Thirty times a second. Everything the views read is written only when it has changed:
    /// an observable that is set every tick has every view that reads it rebuilt every tick,
    /// which was most of the main thread.
    private func tick() {
      guard let host = unit?.host else { return }
      songFrame = max(0, host.songFrame.load(ordering: .relaxed))
      let playing = host.playing.load(ordering: .relaxed)
      if isPlaying != playing { isPlaying = playing }
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
      guard song != nil else { return }
      unit?.send(.seek(songFrame: Int(timeline.start(ofBar: bar) * sampleRate)))
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

    /// The tempo the song is running at: the followed one, or its own.
    var tempo: Double { followedBPM ?? songBPM }

    /// Where the song is in quarter notes, read straight from the engine for the scene's frame
    /// rather than from the last tick, so it is smooth at the display's rate.
    func scoreBeat() -> Double? {
      guard let host = unit?.host, !timeline.times.isEmpty else { return nil }
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

    func analyse() -> Analyser? {
      guard let host = unit?.host else { return nil }
      monitor.withUnsafeMutableBufferPointer { buffer in
        host.recentMix(Analyser.size, into: buffer.baseAddress!)
        analyser.update(UnsafeBufferPointer(buffer))
      }
      return analyser
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

    /// Where every step of the arrangement starts, at the tempo the song is running at. The
    /// transport, the grid and the scene all ask where the song is, many times a frame; planning
    /// the whole song each time was the main thread's entire day, and the tick never ran.
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

    private struct Timeline {
      /// The start of each step, in seconds; `end` is where the last one finishes.
      var times: [Double] = []
      var bars: [Int] = []
      var indices: [Int] = []
      var end = 0.0

      init() {}

      init(song: Song) {
        var time = 0.0
        for bar in 0..<(song.chain.isEmpty ? 1 : song.bars) {
          for index in 0..<song.barLength(forBar: bar) {
            times.append(time)
            bars.append(bar)
            indices.append(index)
            time += 60 / song.bpm(bar: bar, index: index) / 4
          }
        }
        end = time
      }

      /// The last step that had started by `time`.
      func step(at time: Double) -> Int? {
        var low = 0
        var high = times.count
        while low < high {
          let middle = (low + high) / 2
          if times[middle] <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
      }

      /// Where `bar` begins; the end of the song for a bar past its last.
      func start(ofBar bar: Int) -> Double {
        bars.firstIndex(of: bar).map { times[$0] } ?? end
      }
    }
  }
#endif
