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
