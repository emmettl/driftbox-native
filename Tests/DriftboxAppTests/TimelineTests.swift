#if canImport(AVFoundation)
  import DriftboxSeq
  import Testing

  @testable import DriftboxApp

  /// The step times the whole interface is read off. A song whose bars are different lengths at
  /// different tempos is the case that catches anything assuming sixteen steps of one size.
  struct TimelineTests {
    @Test func everyStepIsWhereTheBarsAndTheTempoPutIt() {
      let timeline = Timeline(song: changingSong())
      #expect(timeline.times.count == 24)
      #expect(timeline.bars == [Int](repeating: 0, count: 16) + [Int](repeating: 1, count: 8))
      #expect(timeline.indices == Array(0..<16) + Array(0..<8))
      // Sixteen sixteenths at 120 make two seconds; eight at 240 make half of one.
      #expect(timeline.times[1] == 0.125)
      #expect(timeline.times[16] == 2)
      #expect(timeline.times[17] == 2.0625)
      #expect(timeline.end == 2.5)
      #expect(timeline.length(ofStep: 15) == 0.125)
      #expect(timeline.length(ofStep: 16) == 0.0625)
      // The last step has no next one to run up to, so it runs to the end of the pass.
      #expect(timeline.length(ofStep: 23) == 0.0625)
    }

    @Test func aStepBeginsOnItsOwnTimeAndHoldsUntilTheNext() {
      let timeline = Timeline(song: changingSong())
      #expect(timeline.step(at: -0.001) == nil)
      #expect(timeline.step(at: 0) == 0)
      #expect(timeline.step(at: 0.124) == 0)
      #expect(timeline.step(at: 0.125) == 1)
      #expect(timeline.step(at: 2) == 16)
      // Past the end there is no further step: what happens there is the transport's business.
      #expect(timeline.step(at: 2.5) == 23)
      #expect(timeline.step(at: 60) == 23)
    }

    @Test func aBarBeginsWhereItsFirstStepDoes() {
      let timeline = Timeline(song: changingSong())
      #expect(timeline.start(ofBar: 0) == 0)
      #expect(timeline.start(ofBar: 1) == 2)
      // A bar the song does not reach is the end of the song, which is where a seek to it lands.
      #expect(timeline.start(ofBar: 2) == 2.5)
      #expect(timeline.start(ofBar: 99) == 2.5)
    }

    /// A song with no arrangement is one pattern for ever, which is a single bar.
    @Test func anEmptyChainIsOneBar() {
      var song = steadySong()
      song.chain = []
      let timeline = Timeline(song: song)
      #expect(timeline.times.count == 16)
      #expect(timeline.end == 2)
    }

    @Test func aTimelineWithNoSongAnswersNothing() {
      let timeline = Timeline()
      #expect(timeline.times.isEmpty)
      #expect(timeline.end == 0)
      #expect(timeline.step(at: 0) == nil)
      #expect(timeline.start(ofBar: 0) == 0)
    }
  }
#endif
