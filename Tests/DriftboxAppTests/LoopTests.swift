#if canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The transport's loop, metronome and count-in, from the interface's side: what the controls
  /// decide, and that it reaches the engine.
  @MainActor
  struct LoopTests {
    /// Four bars of one pattern, as four sections.
    func fourBars() -> Song {
      var song = steadySong()
      song.chain = (0..<4).map { _ in ChainStep(pattern: "p") }
      return song
    }

    @Test func aSectionLoopsAndUnloops() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      player.toggleLoop(start: 1, bars: 2)
      #expect(player.loop == Player.LoopRange(start: 1, bars: 2))
      player.toggleLoop(start: 1, bars: 2)
      #expect(player.loop == nil)
      // Stretching takes in whatever is between, on either side.
      player.toggleLoop(start: 2, bars: 1)
      player.extendLoop(toStart: 0, bars: 1)
      #expect(player.loop == Player.LoopRange(start: 0, bars: 3))
      player.extendLoop(toStart: 5, bars: 2)
      #expect(player.loop == Player.LoopRange(start: 0, bars: 7))
    }

    /// Set from the interface, the engine goes round: four seconds of a two-second loop never
    /// leaves it.
    @Test func theLoopReachesTheEngine() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(fourBars(), in: directory)
        player.toggleLoop(start: 2, bars: 1)
        player.seek(toBar: 2)
        player.play()
        for _ in 0..<8 {
          renderAudio(host, frames: 24000)
          player.tick()
          #expect(player.position?.bar == 2)
        }
        // A different song is a different arrangement: the loop does not follow it.
        player.new()
        #expect(player.loop == nil)
      }
    }

    /// With a count-in, play waits a bar at the top while the clicks go, and says so.
    @Test func playCountsInAndAnEditDoesNot() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(fourBars(), in: directory)
        player.stop()
        renderAudio(host, frames: 512)
        player.seek(toStep: 0)
        player.countsIn = true
        player.play()
        renderAudio(host, frames: 48000)
        player.tick()
        #expect(player.countingIn)
        #expect(player.songFrame == 0)
        renderAudio(host, frames: 60000)
        player.tick()
        #expect(!player.countingIn)
        #expect(player.songFrame > 0)
        // An edit while playing re-sends play, which must not count in again.
        player.edit("Set Tempo") { $0.bpm = 121 }
        renderAudio(host, frames: 4800)
        player.tick()
        #expect(!player.countingIn)
      }
    }

    @Test func theLoopsBracketFindsItsBarsAcrossTheGaps() {
      let blocks = [
        SongStrip.Block(index: 0, name: "A", start: 0, bars: 4, colour: 0),
        SongStrip.Block(index: 1, name: "B", start: 4, bars: 2, colour: 1),
      ]
      // Six bars in 600 points of room, three between the two blocks.
      func x(_ bar: Int, end: Bool = false) -> Double {
        SongStrip.x(ofBar: bar, blocks: blocks, room: 600, gap: 3, total: 6, end: end)
      }
      #expect(x(0) == 0)
      #expect(x(2) == 200)
      // The end of the first section is its right edge; the start of the second, after the gap.
      #expect(x(4, end: true) == 400)
      #expect(x(4) == 403)
      #expect(x(6, end: true) == 603)
    }
  }
#endif
