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
        // Following and sending at once is a ring: the virtual source is a source like any other,
        // so our own ticks come straight back in and the two ends chase each other's tempo.
        if followsClock, sendsClock { sendsClock = false }
        // Letting go of the clock means the song's own tempo again, in the engine as well as here.
        guard !followsClock, followedBPM != nil else { return }
        let step = currentStep
        followedBPM = nil
        if let song { unit?.load(song) }
        seek(toStep: step)
        if isPlaying { startEngine() }
      }
    }
    private(set) var followedBPM: Double? {
      didSet { retime() }
    }
    var midiSources: [String] { midi?.sources ?? [] }
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
          stopClock()
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
        stopClock(on: oldValue)
      }
    }

    /// The step whose ticks go out next, and when that step begins on the host clock. Held from
    /// tick to tick rather than worked out afresh each time: `songFrame` only moves when a render
    /// block runs, so a reading of it is anything up to a block old, and deriving every timestamp
    /// from a fresh one would put that jitter into the clock — which is the thing stamping the
    /// messages was for.
    private struct ClockRun {
      var step: Int
      var time: UInt64
    }
    private var clockRun: ClockRun?
    /// Stopped here, but the engine has not said so yet: it hears the stop on its next block and
    /// the tick reads that later still, and without this the clock would take the interval for a
    /// transport that is still running and start itself up again a moment after being stopped.
    private var clockHalted = false
    /// How far past the transport the ticks are written. Comfortably more than the thirtieth of a
    /// second between ticks, so a tick that runs late still finds its steps unsent, and little
    /// enough that a seek throws away only a step or two of what was already queued.
    private static let clockLookahead = 0.2
    /// A disagreement between the clock and the transport larger than this is a seek. Smaller than
    /// the shortest step there can be, so a jump of even one step is noticed.
    private static let clockTolerance = 0.03
    /// And anything smaller is the two clocks parting — the audio device's and the host's are not
    /// the same crystal — which is pulled back a hair at a time. Fifty microseconds a step is a
    /// good half millisecond a second, far more than the drift, and far too little to hear.
    private static let clockSlew = 0.00005

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
      clockOut = MIDIOutput()
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
        startEngine()
      case .resume:
        if let step = command.step { seek(toStep: step) }
        startEngine()
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
      if isPlaying { startEngine() }
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
      driveClock()
    }

    /// Write the next fifth of a second of clock, and start or stop it with the transport.
    ///
    /// Called from the tick, after `songFrame` has been read, because everything here hangs off
    /// it: the ticks are placed on the host clock ahead of the audio and played by the MIDI server
    /// at the stamped moment, rather than sent thirty times a second in whatever bursts the main
    /// thread allows. A cursor over the steps is what keeps that honest — it only moves forward,
    /// so no step's ticks go out twice, and each pass fills it up to the horizon, so none is
    /// missed however late the tick was.
    private func driveClock() {
      guard let out = clockOut else { return }
      if clockDestinations != out.destinations { clockDestinations = out.destinations }
      // Anything that leaves the transport without a song to run is a stop as much as the button
      // is: what is listening should not be left ticking through a song nobody is playing.
      guard sendsClock, song != nil, !timeline.times.isEmpty, isPlaying else {
        if clockRun != nil { stopClock() }
        // The engine has stopped where it was asked to, so a start may be believed again.
        clockHalted = false
        return
      }
      guard !clockHalted else { return }
      let now = MIDIOutput.now()
      // Where the song is at the speakers, not at the render block: the engine has rendered past
      // what is being heard by the device's latency, and the clock belongs with the music.
      let sounding = MIDIOutput.time(now, after: audio.outputNode.presentationLatency)
      let songTime = Double(songFrame) / sampleRate
      let step = timeline.step(at: songTime) ?? 0

      var run: ClockRun
      var correction = 0.0
      if let held = clockRun, held.step < timeline.times.count,
        let drift = clockDrift(held, songTime: songTime, sounding: sounding),
        abs(drift) <= Self.clockTolerance
      {
        run = held
        correction = drift
      } else {
        run = locateClock(step: step, songTime: songTime, sounding: sounding, out: out)
      }

      while MIDIOutput.seconds(from: now, to: run.time) < Self.clockLookahead {
        // The drift is taken out a step at a time rather than all at once, so that no gap between
        // two ticks is off by more than the slew however long the two clocks have been apart.
        if correction != 0 {
          let nudge = min(Self.clockSlew, abs(correction)) * (correction > 0 ? 1 : -1)
          run.time = MIDIOutput.time(run.time, after: nudge)
          correction -= nudge
        }
        let length = timeline.length(ofStep: run.step)
        for scheduled in scheduleClockStep(at: 0, stepSeconds: length) {
          out.send(
            scheduled.message.bytes, to: clockDestination,
            at: MIDIOutput.time(run.time, after: scheduled.time))
        }
        run.time = MIDIOutput.time(run.time, after: length)
        run.step += 1
        if run.step == timeline.times.count { run.step = 0 }
      }
      clockRun = run
    }

    /// How far ahead of the transport the clock has got, in seconds. The run says the song will be
    /// at the top of `step` at `time`, which is a reading of where the song is; the difference
    /// from where it actually is is nothing at all while the two run together. The song loops, so
    /// a difference of nearly a whole pass is the two of them either side of the top rather than a
    /// jump, and wraps to nothing.
    private func clockDrift(_ run: ClockRun, songTime: Double, sounding: UInt64) -> Double? {
      guard timeline.end > 0 else { return nil }
      var drift = timeline.times[run.step] - MIDIOutput.seconds(from: sounding, to: run.time) - songTime
      drift = drift.truncatingRemainder(dividingBy: timeline.end)
      if drift > timeline.end / 2 { drift -= timeline.end }
      if drift < -timeline.end / 2 { drift += timeline.end }
      return drift
    }

    /// Say where the song is and start it there. Starting anywhere but the first step sends the
    /// position before the continue, which is what a device needs to play the right bar and not
    /// merely the right tempo. A clock that was already running is stopped first, and what it had
    /// queued dropped: those ticks are for a bar that is no longer happening.
    private func locateClock(step: Int, songTime: Double, sounding: UInt64, out: MIDIOutput) -> ClockRun {
      if clockRun != nil {
        out.flush(clockDestination)
        out.send(ClockMessage.stop.bytes, to: clockDestination, at: sounding)
      }
      clockRun = nil
      for scheduled in scheduleClockStart(step: step, at: 0) {
        out.send(scheduled.message.bytes, to: clockDestination, at: sounding)
      }
      // Ticking picks up at the next step to begin: the one the transport is already inside has
      // had some of its ticks go by, and sending them now would only bunch them at the start.
      var next = step
      if songTime - timeline.times[step] > 0.001 { next += 1 }
      if next >= timeline.times.count { next = 0 }
      return ClockRun(step: next, time: clockTime(ofStep: next, songTime: songTime, sounding: sounding))
    }

    /// When `step` begins on the host clock, given that the song is at `songTime` at `sounding`.
    private func clockTime(ofStep step: Int, songTime: Double, sounding: UInt64) -> UInt64 {
      var ahead = timeline.times[step] - songTime
      // Behind the transport means the step is the one coming round on the next pass.
      if ahead < 0 { ahead += timeline.end }
      return MIDIOutput.time(sounding, after: ahead)
    }

    /// Stop, and drop whatever was written ahead of it, so that nothing is left ticking behind the
    /// stop and running the other end on by itself.
    private func stopClock(on destination: MIDIOutput.Destination? = nil) {
      defer { clockRun = nil }
      guard let out = clockOut, clockRun != nil else { return }
      let target = destination ?? clockDestination
      out.flush(target)
      out.send(ClockMessage.stop.bytes, to: target, at: MIDIOutput.now())
    }

    func open(_ entry: CatalogueEntry) {
      guard let loaded = Catalogue.song(entry.id) else { return }
      current = entry
      fileURL = nil
      undoManager?.removeAllActions()
      song = loaded
      unit?.load(loaded)
      startEngine()
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
      startEngine()
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
      startEngine()
    }

    func stop() {
      unit?.send(.stop)
      // Here rather than at the next tick: a stop a thirtieth of a second late is a stop that
      // arrives behind ticks the engine is never going to play.
      clockHalted = true
      stopClock()
    }

    /// Everything that starts the engine goes through here, so that a stop the transport has not
    /// caught up with yet cannot leave the clock out held down.
    private func startEngine() {
      clockHalted = false
      unit?.send(.play)
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

      /// How long `step` lasts; the last one runs to the end of the pass.
      func length(ofStep step: Int) -> Double {
        let start = times[step]
        return max(0, (step + 1 < times.count ? times[step + 1] : end) - start)
      }

      /// Where `bar` begins; the end of the song for a bar past its last.
      func start(ofBar bar: Int) -> Double {
        bars.firstIndex(of: bar).map { times[$0] } ?? end
      }
    }
  }
#endif
