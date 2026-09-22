#if canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The arithmetic behind the window's look: what a knob says, where a column falls, how wide a
  /// section of the song is drawn, and what a click on a 303 line lands on.
  @MainActor
  struct InterfaceTests {
    @Test func everyKnobHasALabelAndTheRightUnits() {
      // One spec per parameter, in the parameters' own order.
      #expect(KnobSpec.voice.count == VoiceParams.names.count)
      #expect(KnobSpec.bass.count == BassParams.names.count)
      #expect(KnobSpec.fx.count == FxParams.names.count)
      #expect(KnobSpec.sends.count == SendLevels.names.count)
      // Every effect is in exactly one group.
      #expect(KnobSpec.fxGroups.flatMap(\.knobs).sorted() == Array(FxParams.names.indices))

      #expect(KnobSpec.bipolar(0.5) == "C")
      #expect(KnobSpec.bipolar(0) == "L100")
      #expect(KnobSpec.bipolar(1) == "R100")
      #expect(KnobSpec.percent(0.333) == "33")

      func fx(_ name: String, _ value: Double) -> String {
        KnobSpec.fx[FxParams.names.firstIndex(of: name)!].format(value)
      }
      #expect(fx("drive", 0) == "clean")
      #expect(fx("drive", 0.5) == "50")
      #expect(fx("pcfAmount", 0) == "off")
      #expect(fx("pcfCutoff", 0) == "60Hz")
      #expect(fx("pcfCutoff", 1) == "12000Hz")
      #expect(fx("pcfDecay", 0) == "25ms")
      #expect(fx("reverbSize", 0) == "0.3s")
      #expect(fx("delayTime", 0.5).hasSuffix("/16"))
      #expect(KnobSpec.bass[1].format(0.2) == "saw")
      #expect(KnobSpec.bass[1].format(0.8) == "sqr")
    }

    @Test func columnsStretchBetweenAHittableSizeAndAComfortableOne() {
      let narrow = GridMetrics(steps: 16, width: 300)
      #expect(narrow.stride == GridMetrics.minimumStride)
      let wide = GridMetrics(steps: 16, width: 4000)
      #expect(wide.stride == GridMetrics.maximumStride)
      let between = GridMetrics(steps: 16, width: GridMetrics.labelWidth + 16 * 40)
      #expect(between.stride == 40)
      #expect(between.cell == 40 - GridMetrics.gap)
      // Steps are never shorter than can be hit nor taller than the web draws them.
      #expect(narrow.stepHeight >= 22)
      #expect(wide.stepHeight == 30)
      // A pattern of no steps is still one column, not a division by zero.
      #expect(GridMetrics(steps: 0, width: 500).steps == 1)
    }

    @Test func theSongStripDrawsEachSectionAsWideAsItsBars() {
      var song = steadySong()
      let first = song.patterns[0]
      var second = first
      second.id = "other"
      second.name = "Other"
      song.patterns.append(second)
      song.chain = [
        ChainStep(pattern: first.id, repeat: 4), ChainStep(pattern: "other", repeat: 2),
        ChainStep(pattern: first.id, repeat: 0),
      ]
      let blocks = SongStrip.blocks(song)
      #expect(blocks.map(\.start) == [0, 4, 6])
      // A repeat of nothing still plays a bar, so it is drawn as one.
      #expect(blocks.map(\.bars) == [4, 2, 1])
      // The same pattern is the same colour wherever it comes back.
      #expect(blocks.map(\.colour) == [0, 1, 0])
      #expect(blocks[1].name == "Other")
    }

    @Test func aClickOnA303LineLandsOnTheCellUnderIt() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      let pattern = DriftboxSeq.Pattern(id: "p", name: "P", length: 16)
      let metrics = GridMetrics(steps: 16, width: GridMetrics.labelWidth + 16 * 30)
      let grid = BassGrid(player: player, pattern: pattern, voiceId: "303.a", metrics: metrics, playhead: -1)

      // The top row is the highest note, two octaves up.
      #expect(grid.hit(at: CGPoint(x: 5, y: 1)) == .note(24, step: 0))
      #expect(grid.hit(at: CGPoint(x: 30 * 3 + 5, y: BassGrid.notesHeight - 1)) == .note(0, step: 3))
      #expect(grid.hit(at: CGPoint(x: 5, y: BassGrid.flagsTop + 2)) == .accent(step: 0))
      #expect(grid.hit(at: CGPoint(x: 5, y: BassGrid.flagsTop + BassGrid.flagStride + 2)) == .slide(step: 0))
      // The gap between two columns, and past the last one, are nothing.
      #expect(grid.hit(at: CGPoint(x: 30 - 1, y: 1)) == nil)
      #expect(grid.hit(at: CGPoint(x: 30 * 16 + 5, y: 1)) == nil)
    }

    @Test func aSongsBlurbSplitsIntoWhatItIsAndHowItGoes() {
      let entry = CatalogueEntry(
        id: "x", name: "Acieed", blurb: "Acid house — 126bpm, straight, 303 doing its thing", visual: "")
      #expect(SongRow.genre(of: entry) == "Acid house")
      #expect(SongRow.detail(of: entry) == "126bpm, straight, 303 doing its thing")
      let bare = CatalogueEntry(id: "y", name: "Untitled", blurb: "", visual: "")
      #expect(SongRow.genre(of: bare) == "")
      #expect(SongRow.detail(of: bare) == "")
    }
  }
#endif
