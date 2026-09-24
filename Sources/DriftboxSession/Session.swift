import DriftboxDocument
import DriftboxEngine
import DriftboxHost
import DriftboxScenes
import DriftboxSeq
import Foundation
import Observation

/// What an app holds, on every platform: the song being edited, the engine playing it, where it is,
/// and everything about playing it that is not a view — the transport, the loop, the metronome and
/// the count-in, editing and undo, following a MIDI clock and sending one, and what is remembered
/// between launches.
///
/// It is the groovebox without any platform in it, and every platform's app is built on it. The
/// platform arrives through the ports: `AudioRouting` for where the sound goes, `MIDIInputPort` and
/// `MIDIOutputPort` for the cables, all given by the app, which is the one place that chooses a
/// platform's adapters. A session with none of them — no device, no cables — is the whole of it and
/// none of the hardware, which is the shape a test makes one in.
///
/// Nothing in it keeps time. The app calls `tick` from its own loop, as often as it draws, which
/// on Windows is the window's loop and nothing of Foundation's.
@MainActor
@Observable
public final class Session {
  public private(set) var entries = Catalogue.entries()
  public private(set) var current: CatalogueEntry?
  public private(set) var song: Song? {
    didSet { retime() }
  }
  public private(set) var isPlaying = false
  /// Where the transport is, in the song's own frames.
  public private(set) var songFrame = 0
  /// The engine's rate, which is the host's and not the device's: the device can change under the
  /// engine, and the output converts.
  public var sampleRate: Double { host.sampleRate }
  public private(set) var error: String?
  /// The last voice struck, by index into `allVoices`, and when, in the engine's frames.
  private var lastHits: [Int: Int] = [:]
  /// The voices struck in the last tenth of a second, by index into `allVoices`: for anything that
  /// wants to flash.
  public private(set) var struck: Set<Int> = []
  /// The engine's own clock, which the events are stamped in.
  private var engineFrame = 0
  /// Events since the scene last drew, kept for it here; the grid's flashes read `struck`.
  private var pendingEvents: [EngineEvent] = []
  /// Where the pad is being touched, for the scene's cursor.
  public private(set) var padTouch: SIMD2<Float>?
  /// Whether the visuals are showing.
  public var showsVisuals = true {
    didSet { remembering?.set(showsVisuals, forKey: SessionDefaults.visuals) }
  }
  /// Where the song came from, if a file; where Save goes.
  public private(set) var fileURL: URL?
  /// Whether the song has changed since it was opened or last saved: the window's edited mark, and
  /// what makes closing over the work ask first.
  public private(set) var isEdited = false
  /// The song as it was opened or last saved, which is what edited is measured against: undoing
  /// back to it is not an edit, however many steps it took to get there.
  private var saved: Song?
  /// What to call the song: the catalogue entry's name, or the file's. A window with no song in it
  /// is not an untitled document, it is the application waiting to be given one.
  public var documentName: String { current?.name ?? "Driftbox" }

  private var history = UndoHistory<Song>()
  /// The history's state, mirrored here so that a menu built from it is redrawn when it moves.
  public private(set) var canUndo = false
  public private(set) var canRedo = false
  public private(set) var undoTitle = "Undo"
  public private(set) var redoTitle = "Redo"

  /// The engine behind the transport. Everything the interface reads comes from here, and nothing
  /// it reads is the audio device's.
  public let host: EngineHost

  // MARK: Audio

  private let audio: (any AudioRouting)?
  /// The device chosen to play through, by its id; nil for whatever the system plays through.
  public var outputDevice: String? {
    didSet {
      audio?.chosen = outputDevice
      remembering?.set(outputDevice ?? "", forKey: SessionDefaults.outputDevice)
    }
  }
  /// Every device there is to play through, kept up to date as they come and go.
  public private(set) var outputs: [AudioDevice] = []
  /// The one the sound is going out of: the chosen one while it is there, the system's while it
  /// is not.
  public private(set) var playingThrough: AudioDevice?
  /// The device the system plays through, which is what "the system's" means today.
  public private(set) var systemOutput: AudioDevice?
  /// Why nothing can be heard, while nothing can. Apart from `error`, because it goes away on its
  /// own when a device comes back.
  public private(set) var outputError: String?

  // MARK: MIDI

  private let midi: (any MIDIInputPort)?
  /// Whether anything arriving on a MIDI cable is played at all — the switch over the whole of it,
  /// above the choice of sources below.
  public var listensToMIDI = true {
    didSet { remembering?.set(listensToMIDI, forKey: SessionDefaults.listensToMIDI) }
  }
  /// Sources to hear nothing from, by name: a machine that streams notes at a sequencer it was not
  /// meant to be driving can be silenced without unplugging it, and without silencing the keyboard
  /// that is meant to.
  public var ignoredMIDISources: Set<String> = [] {
    didSet {
      midi?.ignoring = ignoredMIDISources
      remembering?.set(
        ignoredMIDISources.sorted().joined(separator: "\n"), forKey: SessionDefaults.ignoredMIDI)
    }
  }
  /// Every source there is, kept up to date as devices come and go, so a list of them in Settings
  /// changes while it is open rather than the next time it is.
  public private(set) var midiSources: [String] = []
  /// Follow an external MIDI clock: tempo, start, stop and position. Off unless asked for, because
  /// plenty of gear streams clock the moment it is plugged in, and a sequencer that handed its
  /// transport to whatever is on the cable would be taking an instrument away.
  public var followsClock = false {
    didSet {
      // Following and sending are kept apart: a clock followed and sent on round somebody's MIDI
      // thru would chase itself.
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
  public private(set) var followedBPM: Double? {
    didSet { retime() }
  }
  private var follower = ClockFollower()
  /// The song's own tempo, which following leaves alone: the followed tempo is not written in.
  private var songBPM: Double { song?.bpm ?? 120 }

  // MARK: Clock out

  private let clockOut: (any MIDIOutputPort)?
  /// Send MIDI clock out: start, or position and continue when the transport is not at the top;
  /// six ticks a sixteenth while it runs; stop. Off unless asked for, because a clock on the cable
  /// puts everything listening to it under this machine's transport, which is a decision about the
  /// studio and not one a sequencer should make on its own.
  public var sendsClock = false {
    didSet {
      guard sendsClock != oldValue else { return }
      remembering?.set(sendsClock, forKey: SessionDefaults.sendsClock)
      if sendsClock {
        followsClock = false
      } else {
        deliver(cursor.stop(at: HostTime.now()))
      }
    }
  }
  /// Every destination there is, as of the last tick.
  public private(set) var clockDestinations: [String] = []
  /// Where the clock goes: the port of that name, or a source of the app's own on a platform that
  /// can publish one.
  public var clockDestination = MIDIDestination.virtual {
    didSet {
      guard clockDestination != oldValue else { return }
      remembering?.set(clockDestination.stored, forKey: SessionDefaults.clockDestination)
      // Ticks queued at the destination being left would go on arriving after we had stopped
      // talking to it, so it is stopped properly and the new one is located from scratch.
      deliver(cursor.stop(at: HostTime.now()), to: oldValue)
    }
  }
  /// Which step's ticks go out next, and when.
  private var cursor = ClockCursor()

  /// Where what is remembered between launches is kept: the song that was open and the settings.
  /// Nothing at all for a session made without, so a test that opens files by the dozen does not
  /// rewrite what the app will open next.
  public let memory: (any SessionMemory)?
  /// Where a change of setting is written: nowhere while the settings are being read, so that
  /// reading them does not write every one back.
  private var remembering: (any SessionMemory)? { readingSettings ? nil : memory }
  @ObservationIgnored private var readingSettings = false

  /// A session on the platform's parts. `hop` is how word from a MIDI port's own thread reaches the
  /// thread the session lives on — the window's own queue, on Windows. Without ports there is no
  /// such word, and the default, which runs it where it is, is only right for word already there.
  public init(
    host: EngineHost, audio: (any AudioRouting)? = nil, midiIn: (any MIDIInputPort)? = nil,
    midiOut: (any MIDIOutputPort)? = nil, memory: (any SessionMemory)? = nil,
    hop: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() }
  ) {
    self.host = host
    self.audio = audio
    self.midi = midiIn
    self.clockOut = midiOut
    self.memory = memory
    readSettings()

    if let audio {
      audio.chosen = outputDevice
      audio.onChange = { [weak self, weak audio] in
        guard let self, let audio else { return }
        outputs = audio.devices
        playingThrough = audio.current
        systemOutput = audio.systemDefault
        outputError = audio.error
      }
      audio.onChange?()
      audio.attach(host.renderSource)
    }
    if let midiIn {
      midiIn.ignoring = ignoredMIDISources
      midiIn.onNote = { [weak self] note, velocity in
        hop { MainActor.assumeIsolated { self?.midiNote(note, velocity: velocity) } }
      }
      midiIn.onClock = { [weak self] message, time in
        hop { MainActor.assumeIsolated { self?.midiClock(message, at: time) } }
      }
      midiIn.onMessage = { [weak self] bytes in
        hop { MainActor.assumeIsolated { self?.midiMessage(bytes) } }
      }
      midiIn.onSourcesChange = { [weak self] names in
        hop {
          MainActor.assumeIsolated {
            self?.midiSources = names
            self?.midiListener?.midiSources = names
          }
        }
      }
      midiSources = midiIn.sources
    }
    if let midiOut { clockDestinations = midiOut.destinations }
  }

  /// Let the sound go: the engine off the device, and the clock out stopped. What an app does as
  /// it closes.
  public func close() {
    deliver(cursor.halt(at: HostTime.now()))
    audio?.detach(host.renderSource.context)
  }

  /// The settings, as they were left.
  private func readSettings() {
    guard let memory else { return }
    readingSettings = true
    defer { readingSettings = false }
    showsVisuals = memory.object(forKey: SessionDefaults.visuals) as? Bool ?? true
    listensToMIDI = memory.object(forKey: SessionDefaults.listensToMIDI) as? Bool ?? true
    ignoredMIDISources = Set(
      (memory.string(forKey: SessionDefaults.ignoredMIDI) ?? "").split(separator: "\n").map(String.init))
    outputDevice = memory.string(forKey: SessionDefaults.outputDevice).flatMap { $0.isEmpty ? nil : $0 }
    metronome = memory.bool(forKey: SessionDefaults.metronome)
    countsIn = memory.bool(forKey: SessionDefaults.countIn)
    clockDestination = MIDIDestination(stored: memory.string(forKey: SessionDefaults.clockDestination) ?? "")
    sendsClock = memory.bool(forKey: SessionDefaults.sendsClock)
  }

  /// The web app's keys: notes from 33 (A1) play 303 A across two octaves; below that, the drum
  /// voices the grid shows, from note 21 up. A note's velocity past 0.8 is an accent.
  private func midiNote(_ note: Int, velocity: Double) {
    // Something else takes what arrives while it wants it — the rack, while its window is in front.
    guard listensToMIDI, velocity > 0, midiListener?.takesMIDI != true else { return }
    let accent = velocity >= 0.8
    if note >= 33 {
      playNote(semitone: note - 33 - 12, accent: accent)
    } else if note >= 21 {
      strike(index: note - 21, accent: accent)
    }
  }

  /// Every channel message, for whatever else takes MIDI while it does.
  private func midiMessage(_ bytes: [UInt8]) {
    guard listensToMIDI, let listener = midiListener, listener.takesMIDI else { return }
    listener.midi(bytes)
  }

  /// Something else played by the MIDI that arrives, while it wants to be: on the Mac, the rack,
  /// while its window is in front. It hears every channel message then, and the groovebox none.
  public weak var midiListener: (any MIDIListener)? {
    didSet { midiListener?.midiSources = midiSources }
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
  public var currentStep: Int {
    timeline.step(at: Double(songFrame) / sampleRate) ?? 0
  }

  public func seek(toStep step: Int) {
    guard !timeline.times.isEmpty else { return }
    let index = min(max(0, step), timeline.times.count - 1)
    send(.seek(songFrame: Int(timeline.times[index] * sampleRate)))
  }

  /// As often as the app draws. Everything an interface reads is written only when it has changed:
  /// an observable that is set every tick has every view that reads it rebuilt every tick.
  public func tick() {
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
    let lit = Set(lastHits.filter { engineFrame - $0.value < Int(sampleRate / 10) }.keys)
    if struck != lit { struck = lit }
    updatePosition()
    driveClock()
  }

  /// Write the next fifth of a second of clock, and start or stop it with the transport.
  ///
  /// Called from the tick, after `songFrame` has been read, because everything here hangs off it:
  /// the ticks are placed on the host clock ahead of the audio and played by the port at the
  /// stamped moment, rather than sent at every tick in whatever bursts the loop allows. Where the
  /// cursor has got to is what keeps that honest, and it is the cursor that decides; this only
  /// finds the port and the moment, and puts what comes back on it.
  private func driveClock() {
    guard let out = clockOut else { return }
    if clockDestinations != out.destinations { clockDestinations = out.destinations }
    let now = HostTime.now()
    // Anything that leaves the transport without a song to run is a stop as much as the button is:
    // what is listening should not be left ticking through a song nobody is playing. A count-in is
    // not the song yet: what is listening starts with it, not with the clicks.
    guard sendsClock, song != nil, !timeline.times.isEmpty, isPlaying, !countingIn else {
      deliver(cursor.idle(at: now))
      return
    }
    // Where the song is at the speakers, not at the render block: the engine has rendered past what
    // is being heard by the device's latency, and the clock belongs with the music.
    let sounding = HostTime.time(now, after: audio?.latency ?? 0)
    deliver(
      cursor.advance(
        timeline: timeline, songTime: Double(songFrame) / sampleRate, now: now, sounding: sounding))
  }

  /// What the cursor decided, onto the port. The destination is the one in force unless the clock
  /// is being taken off the one it was just moved away from.
  private func deliver(_ messages: [ClockCursor.Out], to destination: MIDIDestination? = nil) {
    guard let out = clockOut, !messages.isEmpty else { return }
    let target = destination ?? clockDestination
    for message in messages {
      switch message {
      case .flush: out.flush(target)
      case .send(let clock, let time): out.send(clock.bytes, to: target, at: time)
      }
    }
  }

  // MARK: - Songs

  public func open(_ entry: CatalogueEntry) {
    guard let loaded = Catalogue.song(entry.id) else { return }
    take(loaded, as: entry, from: nil)
    startEngine()
  }

  /// A song from nowhere the session remembers — a copy of another's, to render — called `name`,
  /// opened stopped. Not remembered as the song to open next time.
  public func open(_ song: Song, named name: String) {
    take(
      song, as: CatalogueEntry(id: "", name: name, blurb: "", visual: song.visual ?? ""), from: nil,
      remembered: false)
  }

  /// A song document from disk, in the web app's format.
  public func open(file url: URL) {
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
    // A document's name is its file's, less whichever of a song's endings it has.
    let name = SongFile.name(fromFileName: url.lastPathComponent)
    let entry = CatalogueEntry(id: url.path, name: name, blurb: "", visual: loaded.visual ?? "")
    take(loaded, as: entry, from: url)
    return true
  }

  /// The song that was open when the app last quit, as it was last saved — and stopped at the top,
  /// because sound nobody asked for is the one thing not worth restoring. A document that has gone
  /// since is forgotten rather than reported.
  public func restore() {
    // Read before the song is opened, since opening one forgets it.
    let pattern = memory?.string(forKey: SessionDefaults.lastPattern)
    restoreSong()
    if let pattern, song?.pattern(id: pattern) != nil { editing = pattern }
  }

  private func restoreSong() {
    guard let memory else { return }
    // Whether a document was remembered is asked apart from where it is now: one whose bookmark no
    // longer resolves, because the file has gone, is still one to forget.
    if memory.object(forKey: SessionDefaults.lastFile) != nil {
      if let url = rememberedFile(in: memory), take(file: url) { return }
      memory.removeObject(forKey: SessionDefaults.lastFile)
    } else if let id = memory.string(forKey: SessionDefaults.lastSong),
      let entry = entries.first(where: { $0.id == id }), let loaded = Catalogue.song(id)
    {
      take(loaded, as: entry, from: nil)
    }
  }

  /// Where the document last open was. A bookmark where there are bookmarks — so one renamed or
  /// moved in the Finder since is still found — and its path where there are not, as on Windows.
  private func rememberedFile(in memory: any SessionMemory) -> URL? {
    #if canImport(Darwin)
      guard let bookmark = memory.data(forKey: SessionDefaults.lastFile) else { return nil }
      var stale = false
      return try? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    #else
      return memory.string(forKey: SessionDefaults.lastFile).map { URL(fileURLWithPath: $0) }
    #endif
  }

  /// Write down what is open. A catalogue song by its id, a document by where it is, and a new song
  /// not at all: it has nowhere to come back from, and quitting has already asked whether to save.
  private func remember(_ entry: CatalogueEntry, at url: URL?) {
    guard let memory else { return }
    memory.removeObject(forKey: SessionDefaults.lastSong)
    memory.removeObject(forKey: SessionDefaults.lastFile)
    if let url {
      #if canImport(Darwin)
        memory.set(try? url.bookmarkData(), forKey: SessionDefaults.lastFile)
      #else
        memory.set(url.path, forKey: SessionDefaults.lastFile)
      #endif
    } else if !entry.id.isEmpty {
      memory.set(entry.id, forKey: SessionDefaults.lastSong)
    }
  }

  /// An empty song to start from. It arrives with the 909's core voices and a 303 line already laid
  /// out, because the grid draws the lanes a pattern has and a song with none is a wall.
  public func new() {
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
  private func take(_ loaded: Song, as entry: CatalogueEntry, from url: URL?, remembered: Bool = true) {
    // Whatever was linked to the rack is let go of, before anything else arrives.
    if let link = rackLink {
      rackLink = nil
      link.ended()
    }
    current = entry
    fileURL = url
    editing = nil
    loop = nil
    if remembered { remember(entry, at: url) }
    history.clear()
    refreshUndo()
    song = loaded
    saved = loaded
    isEdited = false
    load(loaded)
  }

  /// Write the song back where it came from. Nothing without a file: that is Save As's question.
  public func save() {
    guard let fileURL else { return }
    save(to: fileURL)
  }

  public func save(to url: URL) {
    guard let song else { return }
    do {
      try Data(SongCodec.encode(song).utf8).write(to: url)
      fileURL = url
      saved = song
      isEdited = false
      // Saving under a new name renames the window with it, as a document's title follows its file
      // rather than whatever it was called when it was opened.
      let name = SongFile.name(fromFileName: url.lastPathComponent)
      current = CatalogueEntry(
        id: url.path, name: name, blurb: current?.blurb ?? "", visual: current?.visual ?? "")
      // Saved somewhere new, it comes back from there.
      if let current { remember(current, at: url) }
    } catch {
      self.error = "\(error)"
    }
  }

  // MARK: - The transport

  /// Jump to the start of a bar of the arrangement.
  public func seek(toBar bar: Int) {
    guard song != nil else { return }
    send(.seek(songFrame: Int(timeline.start(ofBar: bar) * sampleRate)))
  }

  /// Where each entry of the chain begins, in bars. A song with no chain is one pattern playing for
  /// ever, which is a single section.
  public var sectionBars: [Int] {
    guard let song, !song.chain.isEmpty else { return [0] }
    var bar = 0
    return song.chain.map { entry in
      defer { bar += max(1, entry.repeat) }
      return bar
    }
  }

  /// Move the transport a chain entry at a time, wrapping at both ends because the chain does.
  public func skip(sections delta: Int) {
    let starts = sectionBars
    guard song != nil, !starts.isEmpty else { return }
    let bar = position?.bar ?? 0
    let here = starts.lastIndex { $0 <= bar } ?? 0
    let next = (here + delta % starts.count + starts.count) % starts.count
    seek(toBar: starts[next])
  }

  /// Play because someone asked to: from a stop, that counts in first if a count-in is set.
  public func play() {
    cursor.resume()
    send(.start)
  }

  public func stop() {
    send(.stop)
    // Here rather than at the next tick: a stop a tick late is a stop that arrives behind ticks the
    // engine is never going to play.
    deliver(cursor.halt(at: HostTime.now()))
  }

  public func toggle() {
    isPlaying ? stop() : play()
  }

  /// Everything that starts the engine goes through here, so that a stop the transport has not
  /// caught up with yet cannot leave the clock out held down.
  private func startEngine() {
    cursor.resume()
    send(.play)
  }

  // MARK: Loop, metronome, count-in

  /// A click on every beat while the song plays.
  public var metronome = false {
    didSet {
      guard metronome != oldValue else { return }
      send(.metronome(metronome))
      remembering?.set(metronome, forKey: SessionDefaults.metronome)
    }
  }

  /// A bar of clicks before the song moves, when play is pressed from a stop.
  public var countsIn = false {
    didSet {
      guard countsIn != oldValue else { return }
      send(.countIn(bars: countsIn ? 1 : 0))
      remembering?.set(countsIn, forKey: SessionDefaults.countIn)
    }
  }

  /// Whether the song is waiting on its count-in.
  public private(set) var countingIn = false

  /// A run of whole bars to play round and round.
  public struct LoopRange: Equatable, Sendable {
    public var start: Int
    public var bars: Int
    public var end: Int { start + bars }
    public init(start: Int, bars: Int) {
      self.start = start
      self.bars = bars
    }
    public func contains(bar: Int) -> Bool { bar >= start && bar < end }
  }

  /// The bars being looped. The engine goes round at the loop's end on its exact frame, and holds
  /// the loop in bars, so an edit — which moves every frame — leaves it where it was.
  public var loop: LoopRange? {
    didSet {
      guard loop != oldValue else { return }
      send(.loop(startBar: loop?.start ?? 0, bars: loop?.bars ?? 0))
    }
  }

  /// Loop the section from `start` for `bars`, or stop looping it if it already is.
  public func toggleLoop(start: Int, bars: Int) {
    let range = LoopRange(start: max(0, start), bars: max(1, bars))
    loop = loop == range ? nil : range
  }

  /// Loop the section the transport is in, or stop looping it.
  public func loopSection() {
    let starts = sectionBars
    let bar = position?.bar ?? 0
    guard let at = starts.lastIndex(where: { $0 <= bar }), let song else { return }
    let end = at + 1 < starts.count ? starts[at + 1] : song.bars
    toggleLoop(start: starts[at], bars: max(1, end - starts[at]))
  }

  /// Stretch the loop to take in the section from `start` for `bars`, whichever side it is on.
  public func extendLoop(toStart start: Int, bars: Int) {
    guard let current = loop else { return toggleLoop(start: start, bars: bars) }
    let from = min(current.start, start)
    let to = max(current.end, start + max(1, bars))
    loop = LoopRange(start: from, bars: to - from)
  }

  // MARK: - Playing it by hand

  /// The voices the song uses, in the order the grid shows them.
  public var usedVoices: [Voice] {
    guard let pattern = shownPattern else { return [] }
    return allVoices.filter { pattern.tracks[$0.id] != nil }
  }

  /// Strike the `index`th voice of the grid, now, with the song's knobs for it.
  public func strike(index: Int, accent: Bool) {
    guard let song, usedVoices.indices.contains(index) else { return }
    let voice = usedVoices[index]
    let group =
      voice.choke.flatMap { ["808.hats", "909.hats"].firstIndex(of: $0) }.map { UInt8($0 + 1) } ?? 0
    let hit = host.preparer.prepare(
      voice.build(song.kit.params[voice.id] ?? VoiceParams(), accent: accent ? 1 : 0.55), voiceId: voice.id,
      at: 0, sends: song.kit.sends[voice.id] ?? SendLevels(), chokeGroup: group)
    send(.strike(hit))
  }

  /// Play a note on 303 A, now, with the song's panel for it.
  public func playNote(semitone: Int, accent: Bool) {
    guard let song else { return }
    let params = song.kit.bass["303.a"] ?? BassParams()
    let step = BassStep(note: Double(max(0, min(24, semitone + 12))), accent: accent)
    guard
      let note = bassNote(
        params: params, step: step, previous: .rest, stepSeconds: secondsPerStep(bpm: song.bpm))
    else { return }
    send(.note(line: 0, note))
  }

  /// The performance filter's pad, touched at `x`, `y`, 0...1 from the bottom left.
  public func pad(x: Double, y: Double) {
    padTouch = SIMD2(Float(x), Float(y))
    send(.pad(x: x, y: y))
  }

  public func padRelease() {
    padTouch = nil
    send(.padRelease)
  }

  // MARK: - What the scenes read

  /// What the engine has reported since the scene last asked.
  public func takeEvents() -> [EngineEvent] {
    defer { pendingEvents.removeAll() }
    return pendingEvents
  }

  /// The tempo the song is running at: the followed one, or its own.
  public var tempo: Double { followedBPM ?? songBPM }

  /// Where the song is in quarter notes, read straight from the engine for the scene's frame rather
  /// than from the last tick, so it is smooth at the display's rate.
  public func scoreBeat() -> Double? {
    let frame = host.songFrame.load(ordering: .relaxed)
    guard frame >= 0 else { return nil }
    return timeline.scoreBeat(at: Double(frame) / sampleRate)
  }

  /// The mix's bass, mids and highs for the scene, from the last two thousand frames it heard.
  private let analyser = Analyser()
  private var monitor = [Float](repeating: 0, count: Analyser.size)
  private var analysedAt = -1

  /// The spectrum is only worked out again when new audio has arrived. That is what Web Audio's
  /// analyser does — two reads inside one render quantum get the same answer — and it matters
  /// because the smoothing is applied per analysis: a display faster than the audio blocks, or two
  /// views asking in one frame, would otherwise make the bands fall faster than they do on the web.
  public func analyse() -> Analyser {
    let written = host.mixWritten
    if written == analysedAt { return analyser }
    analysedAt = written
    monitor.withUnsafeMutableBufferPointer { buffer in
      host.recentMix(Analyser.size, into: buffer.baseAddress!)
      analyser.update(UnsafeBufferPointer(buffer))
    }
    return analyser
  }

  /// The last `count` frames of the mix, oldest first: what a scope draws.
  public func recentMix(_ count: Int) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { host.recentMix(count, into: $0.baseAddress!) }
    return out
  }

  /// The loudest sample of the last audio block, each side.
  public var peaks: (left: Float, right: Float) {
    (
      Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
      Float(bitPattern: host.peakRight.load(ordering: .relaxed))
    )
  }

  /// A frame's worth of everything a scene is fed, at `time` on the app's clock.
  public func sceneInput(time: Double, pixelRatio: Float) -> SceneInput {
    let analyser = analyse()
    let peaks = peaks
    return SceneInput(
      time: time, peakLeft: peaks.left, peakRight: peaks.right, events: takeEvents(), touch: padTouch,
      bar: position?.bar ?? 0, step: position?.step ?? 0, running: isPlaying, bpm: tempo,
      scoreBeat: scoreBeat(), levels: analyser.levels(), wideLevels: analyser.wideLevels(),
      bands: analyser.bands(16), pixelRatio: pixelRatio)
  }

  // MARK: - Editing

  /// Which voice's panel is showing.
  public var selectedVoice: String?
  /// A pattern chosen to edit, or nil to follow the transport. Remembered with the song, so the
  /// next launch opens on the pattern that was being worked on rather than the first one.
  public var editing: String? {
    didSet {
      guard editing != oldValue, let memory else { return }
      if let editing {
        memory.set(editing, forKey: SessionDefaults.lastPattern)
      } else {
        memory.removeObject(forKey: SessionDefaults.lastPattern)
      }
    }
  }

  /// Clicking a 909 step marks a flam rather than cycling the step.
  public var flamMode = false

  /// A lane or line copied, to paste into another. The app's own, not the system's clipboard:
  /// nothing outside Driftbox could do anything with it.
  public enum LaneClipboard: Sendable {
    case drum(DrumLaneClipboard)
    case bass(BassLineClipboard)
  }
  public private(set) var laneClipboard: LaneClipboard?

  /// The pattern the grid shows.
  public var shownPattern: DriftboxSeq.Pattern? {
    if let editing, let chosen = song?.pattern(id: editing) { return chosen }
    return position?.pattern ?? song?.patterns.first
  }

  /// Change the pattern the grid shows, undoably, under `name`.
  public func editShown(_ name: String, _ change: (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern) {
    guard let id = shownPattern?.id else { return }
    editPattern(id, name, change)
  }

  public func editPattern(
    _ id: String, _ name: String, _ change: (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern
  ) {
    edit(name) { song in
      guard let at = song.patterns.firstIndex(where: { $0.id == id }) else { return }
      song.patterns[at] = change(song.patterns[at])
    }
  }

  public func copyLane(_ voiceId: String) {
    guard let pattern = shownPattern else { return }
    laneClipboard =
      voiceId.hasPrefix("303.")
      ? .bass(pattern.copyingBassLine(voiceId)) : .drum(pattern.copyingDrumLane(voiceId))
  }

  public func cutLane(_ voiceId: String) {
    copyLane(voiceId)
    editShown(voiceId.hasPrefix("303.") ? "Cut Line" : "Cut Lane") {
      voiceId.hasPrefix("303.") ? $0.clearingBassLine(voiceId) : $0.clearingTrack(voiceId)
    }
  }

  /// Whether what is on the clipboard can go into `voiceId`: a drum lane into a drum lane, a line
  /// into a line.
  public func canPasteLane(into voiceId: String) -> Bool {
    switch laneClipboard {
    case .drum: !voiceId.hasPrefix("303.")
    case .bass: voiceId.hasPrefix("303.")
    case nil: false
    }
  }

  public func pasteLane(into voiceId: String) {
    switch laneClipboard {
    case .drum(let lane) where !voiceId.hasPrefix("303."):
      editShown("Paste Lane") { $0.pastingDrumLane(voiceId, lane) }
    case .bass(let line) where voiceId.hasPrefix("303."):
      editShown("Paste Line") { $0.pastingBassLine(voiceId, line) }
    default:
      break
    }
  }

  /// Change the song and have the engine take it up where it is, without stopping. Undoable under
  /// `name`, which is what the Edit menu offers to undo — "Undo Set Step", not "Undo".
  public func edit(_ name: String = "Edit", _ change: (inout Song) -> Void) {
    guard let before = song else { return }
    var edited = before
    change(&edited)
    history.record(name, before: before, after: edited)
    apply(edited)
  }

  public func undo() {
    guard let before = history.undo() else { return }
    apply(before)
  }

  public func redo() {
    guard let after = history.redo() else { return }
    apply(after)
  }

  private func refreshUndo() {
    if canUndo != history.canUndo { canUndo = history.canUndo }
    if canRedo != history.canRedo { canRedo = history.canRedo }
    if undoTitle != history.undoTitle { undoTitle = history.undoTitle }
    if redoTitle != history.redoTitle { redoTitle = history.redoTitle }
  }

  /// The song as it is now, whether by an edit or by going back or forward through them: into the
  /// engine at the same place, without stopping.
  private func apply(_ edited: Song) {
    song = edited
    // Linked, each edit is kept by the rack as it is made, so there is nothing here to save.
    if rackLink != nil { saved = edited }
    isEdited = edited != saved
    refreshUndo()
    let position = songFrame
    load(edited)
    send(.seek(songFrame: position))
    if isPlaying { startEngine() }
    rackLink?.edited(edited)
  }

  // MARK: - The engine, and a take of what it is told

  /// Everything the session tells the engine goes through here, so a take hears all of it.
  private func send(_ command: Command) {
    host.send(command)
    recording?.events.append((host.engineFrame.load(ordering: .relaxed), .command(command)))
  }

  private func load(_ song: Song) {
    host.load(song)
    recording?.events.append((host.engineFrame.load(ordering: .relaxed), .song(song)))
  }

  /// The performance being recorded, while one is.
  private var recording: Take?
  public private(set) var isRecording = false
  /// When the take began, on the engine's clock, for how long it has been going.
  public var recordingSeconds: Double {
    guard let recording else { return 0 }
    return Double(max(0, host.engineFrame.load(ordering: .relaxed) - recording.start)) / sampleRate
  }

  /// Begin recording what is played from here: the engine as it stands, then everything done to it.
  /// A command sent now takes effect at the start of the engine's next block, which is the frame its
  /// clock has reached — or the one after, if a block is being rendered as it is sent, which is the
  /// same block's latency the performance had live.
  public func startRecording(scene: String? = nil) {
    guard let song, !isRecording else { return }
    recording = Take(
      sampleRate: sampleRate, start: host.engineFrame.load(ordering: .relaxed),
      end: host.engineFrame.load(ordering: .relaxed), song: song, songFrame: songFrame, playing: isPlaying,
      loop: loop.map { ($0.start, $0.bars) }, metronome: metronome, scene: scene)
    isRecording = true
  }

  /// A song a take loaded, as the take loaded it: into the engine and what the session shows, and
  /// nothing else — an edit left the loop, the history and the rest as they were.
  public func takeUp(_ song: Song) {
    self.song = song
    load(song)
  }

  /// The take, ended now; nil if none was being made.
  public func stopRecording() -> Take? {
    guard var finished = recording else { return nil }
    finished.end = host.engineFrame.load(ordering: .relaxed)
    recording = nil
    isRecording = false
    return finished
  }

  /// The visuals switched scene, for a take to see it too.
  public func noteScene(_ id: String?) {
    recording?.events.append((host.engineFrame.load(ordering: .relaxed), .scene(id)))
  }

  // MARK: - The rack's song

  /// The rack's song, open here to be edited: each edit goes straight back to the rack, which plays
  /// it on in place, and the link ends when anything else is opened here.
  private var rackLink: (edited: (Song) -> Void, ended: () -> Void)?
  public var linkedToRack: Bool { rackLink != nil }

  /// Open the rack's `song`, called `name`, to edit it for the rack. Not remembered as the song to
  /// open next time, since it lives in the rack; and not played here, since the rack is playing it.
  public func link(
    _ song: Song, name: String, edited: @escaping (Song) -> Void, ended: @escaping () -> Void
  ) {
    if isPlaying { stop() }
    take(
      song, as: CatalogueEntry(id: "rack", name: name, blurb: "In the rack", visual: song.visual ?? ""),
      from: nil, remembered: false)
    rackLink = (edited, ended)
  }

  /// Let the rack's song go, keeping it here as a song of its own.
  public func unlinkRack() { rackLink = nil }

  // MARK: - Where the song is

  public struct Position: Equatable, Sendable {
    /// Which bar of the arrangement, and which step in it.
    public var bar: Int
    public var step: Int
    public var pattern: DriftboxSeq.Pattern?

    /// The same place in the same pattern; the pattern's contents are the song's business.
    public static func == (a: Position, b: Position) -> Bool {
      a.bar == b.bar && a.step == b.step && a.pattern?.id == b.pattern?.id
    }
  }

  /// The step the transport is on. Written when the step changes, and when the song does.
  public private(set) var position: Position?

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

/// Where a session keeps what it remembers: the Mac app's own keys, so that its preferences come
/// with it when it moves onto the session.
enum SessionDefaults {
  static let visuals = "visuals.run"
  static let listensToMIDI = "midi.listens"
  /// The sources not listened to, one name to a line. Stored as what is ignored rather than what is
  /// heard, so a device plugged in for the first time is heard, as every source was before there
  /// was a choice.
  static let ignoredMIDI = "midi.ignored"
  static let sendsClock = "clock.sends"
  static let metronome = "transport.metronome"
  static let countIn = "transport.countIn"
  static let clockDestination = "clock.destination"
  /// The device to play through, by its id; empty for the system's.
  static let outputDevice = "audio.output"
  static let lastSong = "song.last.catalogue"
  static let lastFile = "song.last.file"
  /// The pattern chosen to edit in that song, if one was rather than following the transport.
  static let lastPattern = "song.last.pattern"
}

extension MIDIDestination {
  /// The destination as something to remember it by, as the Mac app remembers it. The app's own
  /// source has no name, and the empty string is how it says so.
  var stored: String {
    if case .port(let name) = self { return name }
    return ""
  }

  init(stored: String) {
    self = stored.isEmpty ? .virtual : .port(stored)
  }
}

/// What a session remembers between launches is kept in: `UserDefaults`, on the Mac and Windows —
/// the calls here are its own, so it needs nothing more than to say so. Not on Android, where it
/// is the old Foundation and the thirty megabytes of internationalisation that come with it, and
/// where the app will keep what it remembers the way Android apps do.
/// Something besides the groovebox that MIDI can play: the rack, on the Mac. While `takesMIDI`, it
/// hears every channel message the session is sent, and is told the sources as they change.
@MainActor
public protocol MIDIListener: AnyObject {
  var takesMIDI: Bool { get }
  func midi(_ bytes: [UInt8])
  var midiSources: [String] { get set }
}

public protocol SessionMemory: AnyObject {
  func object(forKey key: String) -> Any?
  func string(forKey key: String) -> String?
  func bool(forKey key: String) -> Bool
  func data(forKey key: String) -> Data?
  func set(_ value: Any?, forKey key: String)
  func removeObject(forKey key: String)
}

#if !os(Android)
  extension UserDefaults: SessionMemory {}
#endif
