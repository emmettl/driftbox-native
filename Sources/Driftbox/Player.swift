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
    }

    func open(_ entry: CatalogueEntry) {
      guard let loaded = Catalogue.song(entry.id) else { return }
      current = entry
      song = loaded
      unit?.load(loaded)
      unit?.send(.play)
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

    /// Change the song and have the engine take it up where it is, without stopping.
    func edit(_ change: (inout Song) -> Void) {
      guard var edited = song else { return }
      change(&edited)
      song = edited
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
