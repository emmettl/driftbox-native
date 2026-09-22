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
    /// Where the song came from, if a file; where Save goes.
    var fileURL: URL?
    var undoManager: UndoManager?

    private let audio = AVAudioEngine()
    private var unit: DriftboxAudioUnit?
    private var clock: Timer?

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
    }

    private func tick() {
      guard let host = unit?.host else { return }
      songFrame = max(0, host.songFrame.load(ordering: .relaxed))
      isPlaying = host.playing.load(ordering: .relaxed)
      host.collect()
      engineFrame = host.engineFrame.load(ordering: .relaxed)
      while let event = host.nextEvent() {
        if event.kind == .hit { lastHits[event.voice] = event.frame }
      }
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

    func pad(x: Double, y: Double) {
      unit?.send(.pad(x: x, y: y))
    }

    func padRelease() {
      unit?.send(.padRelease)
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
