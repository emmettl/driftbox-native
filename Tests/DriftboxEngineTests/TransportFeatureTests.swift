import DriftboxEngine
import DriftboxSeq
import Testing

/// The transport's own features: looping a run of bars, the metronome, and the count-in. A song
/// of four sixteen-step bars at 120 bpm, so a bar is two seconds and exactly 96,000 frames.
struct TransportFeatureTests {
  static let sampleRate = 48000.0
  static let bar = 96000

  /// Four bars, a kick on each bar's first step, or nothing at all.
  static func song(kicks: Bool = true) -> Song {
    var pattern = Pattern(id: "p", name: "P", length: 16)
    var track = [StepValue](repeating: .off, count: 16)
    if kicks { track[0] = .on }
    pattern.tracks["909.bd"] = track
    var song = Song(bpm: 120, patterns: [pattern])
    song.chain = [ChainStep(pattern: "p", repeat: 4)]
    return song
  }

  final class Rig {
    var engine: SongEngine
    var compiled: [UnsafeMutablePointer<CompiledSong>] = []

    init(_ song: Song) {
      engine = SongEngine(sampleRate: TransportFeatureTests.sampleRate, voiceCapacity: 16)
      load(song)
    }

    func load(_ song: Song) {
      let made = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
      made.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
      compiled.append(made)
      engine.load(made)
    }

    deinit {
      engine.load(nil)
      for song in compiled {
        song.deinitialize(count: 1)
        song.deallocate()
      }
    }

    /// Render `frames` in blocks of `block`, returning the left channel and every hit's frame.
    func render(_ frames: Int, block: Int = 333) -> (left: [Float], hits: [Int]) {
      var left = [Float](repeating: 0, count: frames)
      var right = [Float](repeating: 0, count: frames)
      var hits: [Int] = []
      var done = 0
      while done < frames {
        let count = min(block, frames - done)
        left.withUnsafeMutableBufferPointer { l in
          right.withUnsafeMutableBufferPointer { r in
            engine.render(frames: count, left: l.baseAddress! + done, right: r.baseAddress! + done)
          }
        }
        while let event = engine.events.receive() {
          if event.kind == .hit { hits.append(event.frame) }
        }
        done += count
      }
      return (left, hits)
    }
  }

  /// Loop bars one and two of four: the transport runs into the loop, goes round at its end on
  /// the exact frame, and never reaches bar three. Every kick lands on a bar line.
  @Test func aLoopGoesRoundOnItsExactFrame() {
    let rig = Rig(Self.song())
    rig.engine.setLoop(startBar: 1, bars: 2)
    rig.engine.play()
    var seen: [Int] = []
    var hits: [Int] = []
    for _ in 0..<40 {
      hits += rig.render(Self.bar * 7 / 40).hits
      seen.append(rig.engine.songFrame())
    }
    #expect(seen.allSatisfy { $0 < 3 * Self.bar })
    #expect(seen.last! >= Self.bar)
    // Seven bars of time, a kick at the top of each: the loop added no gap and lost no bar.
    #expect(hits == (0..<7).map { $0 * Self.bar })
  }

  /// Rendered up to the loop's end in one call, the transport is at the loop's start after it.
  @Test func theTurnIsSampleAccurate() {
    let rig = Rig(Self.song())
    rig.engine.setLoop(startBar: 0, bars: 1)
    rig.engine.play()
    _ = rig.render(Self.bar - 1, block: Self.bar - 1)
    #expect(rig.engine.songFrame() == Self.bar - 1)
    _ = rig.render(1, block: 1)
    #expect(rig.engine.songFrame() == 0)
  }

  /// Past the loop when it is set, the transport finishes its bar and then goes back.
  @Test func pastTheLoopItGoesBackAtTheNextBar() {
    let rig = Rig(Self.song())
    rig.engine.play()
    rig.engine.seek(toSongFrame: 3 * Self.bar + 1000)
    rig.engine.setLoop(startBar: 0, bars: 2)
    _ = rig.render(Self.bar - 1000, block: 4096)
    #expect(rig.engine.songFrame() == 0)
  }

  /// An edit recompiles the song and moves every frame; the loop is in bars, so it holds.
  @Test func aLoopSurvivesAnEdit() {
    let rig = Rig(Self.song())
    rig.engine.setLoop(startBar: 2, bars: 1)
    rig.engine.play()
    var edited = Self.song()
    edited.bpm = 90
    rig.load(edited)
    rig.engine.seek(toSongFrame: 0)
    let slowBar = 128_000
    var seen: [Int] = []
    for _ in 0..<30 {
      _ = rig.render(slowBar / 5)
      seen.append(rig.engine.songFrame())
    }
    #expect(seen.suffix(10).allSatisfy { $0 >= 2 * slowBar && $0 < 3 * slowBar })
  }

  /// Clicks on the beat, the bar's first higher and louder, and nothing when it is off.
  @Test func theMetronomeClicksOnTheBeat() {
    let rig = Rig(Self.song(kicks: false))
    rig.engine.play()
    let silent = rig.render(Self.bar / 2).left
    #expect(silent.map(abs).max()! < 1e-6)

    rig.engine.seek(toSongFrame: 0)
    rig.engine.metronome = true
    let beat = Self.bar / 4
    let clicks = rig.render(Self.bar).left
    func peak(_ range: Range<Int>) -> Float { clicks[range].map(abs).max()! }
    let strong = peak(0..<3000)
    let weak = peak(beat..<beat + 3000)
    // The peaks Chromium renders the reference's clicks at, measured through `renderVoice` in an
    // OfflineAudioContext at 48kHz. (The reference's own comment gives 0.70 and 0.50, which the
    // browser does not bear out; the ratio between them it does.)
    #expect(abs(strong - 0.34060) < 1e-4)
    #expect(abs(weak - 0.22757) < 1e-4)
    // Silence between the clicks, and a click on every beat.
    #expect(peak(4000..<beat - 100) < 1e-4)
    for index in 1..<4 { #expect(abs(peak(index * beat..<index * beat + 3000) - 0.22757) < 1e-4) }
  }

  /// The click goes round the master, so the pad sweeping the filter shut leaves it alone.
  @Test func thePadCannotSwallowTheClick() {
    let rig = Rig(Self.song(kicks: false))
    rig.engine.metronome = true
    rig.engine.pad.set(x: 0, y: 0, atFrame: 0)
    rig.engine.play()
    let clicks = rig.render(3000).left
    #expect(abs(clicks.map(abs).max()! - 0.34060) < 1e-4)
  }

  /// A bar of clicks, the song holding at its start, then the song — on the count-in's last frame.
  @Test func aCountInHoldsTheSongForABarOfClicks() {
    let rig = Rig(Self.song())
    rig.engine.countInBars = 1
    rig.engine.start()
    let counted = rig.render(Self.bar)
    #expect(rig.engine.songFrame() == 0)
    #expect(counted.hits.isEmpty)
    let beat = Self.bar / 4
    for index in 0..<4 {
      let click = counted.left[index * beat..<index * beat + 3000].map(abs).max()!
      #expect(abs(click - (index == 0 ? 0.34060 : 0.22757)) < 1e-4, "beat \(index)")
    }
    #expect(rig.engine.countInLeft == 0)
    let playing = rig.render(Self.bar / 2)
    #expect(playing.hits == [Self.bar])
    #expect(rig.engine.songFrame() == Self.bar / 2)
  }

  /// Only a start from a stop counts in: an edit re-sending play, or a start while running, does not.
  @Test func onlyAStartFromAStopCountsIn() {
    let rig = Rig(Self.song())
    rig.engine.countInBars = 1
    rig.engine.play()
    #expect(rig.engine.countInLeft == 0)
    rig.engine.start()
    #expect(rig.engine.countInLeft == 0)
    rig.engine.stop()
    rig.engine.start()
    #expect(rig.engine.countInLeft == Self.bar)
    rig.engine.stop()
    #expect(rig.engine.countInLeft == 0)
  }
}
