#if canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxHost
  import DriftboxSeq
  import Foundation

  @testable import DriftboxApp

  /// One pattern of sixteen at 120: a step is an eighth of a second and a pass is two seconds, so
  /// every time a test works out by hand is exact in binary.
  func steadySong(bpm: Double = 120, length: Int = 16) -> Song {
    var pattern = DriftboxSeq.Pattern(id: "p", name: "Pattern 1", length: length)
    pattern.tracks["909.bd"] = [StepValue](repeating: .on, count: length)
    pattern.bass["303.a"] = [BassStep](repeating: .rest, count: length)
    var song = Song(bpm: bpm, patterns: [pattern])
    song.chain = [ChainStep(pattern: pattern.id)]
    return song
  }

  /// A bar of sixteen at 120 followed by a bar of eight at 240: a song that changes both the things
  /// the step times are made of, and in opposite directions.
  func changingSong() -> Song {
    var long = DriftboxSeq.Pattern(id: "long", name: "Long", length: 16)
    long.tracks["909.bd"] = [StepValue](repeating: .on, count: 16)
    var short = DriftboxSeq.Pattern(id: "short", name: "Short", length: 8)
    short.tracks["909.sd"] = [StepValue](repeating: .on, count: 8)
    var song = Song(bpm: 120, patterns: [long, short])
    song.chain = [ChainStep(pattern: "long"), ChainStep(pattern: "short")]
    song.automation = [
      AutomationLane(
        target: AutomationTarget.bpm, interpolation: .hold,
        points: [
          AutomationPoint(bar: 0, index: 0, value: 120), AutomationPoint(bar: 1, index: 0, value: 240),
        ])
    ]
    return song
  }

  /// Run the engine for `frames`, in the blocks an audio device would ask for.
  func renderAudio(_ host: EngineHost, frames: Int) {
    var left = [Float](repeating: 0, count: 512)
    var right = [Float](repeating: 0, count: 512)
    var done = 0
    while done < frames {
      let count = min(512, frames - done)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: count, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
      done += count
    }
  }

  /// Somewhere of its own for a test that writes files, taken away again afterwards.
  func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-app-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
  }

  /// A player with no audio device, holding `song` and playing it. The song arrives through a file
  /// because that is how one arrives in the application, and the engine is rendered by the caller.
  @MainActor
  func openedPlayer(_ song: Song, named name: String = "Test", in directory: URL) throws -> (
    player: Player, host: EngineHost
  ) {
    let url = directory.appendingPathComponent("\(name).song.json")
    try Data(SongCodec.encode(song).utf8).write(to: url)
    let host = EngineHost(sampleRate: 48000)
    let player = Player(host: host)
    player.open(file: url)
    return (player, host)
  }
#endif
