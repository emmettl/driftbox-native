import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxRackSession

/// Samples in the rack: the reference's arithmetic, and the breaks the factory patches are built
/// around.
struct SampleMathTests {
  @Test func aLoopsTempoIsTheOneAtWhichItIsWholeBars() {
    #expect(abs(SampleMath.tempoForBars(1.3793, 1) - 174) < 0.05)
    #expect(SampleMath.tempoForBars(2, 1) == 120)
    #expect(SampleMath.tempoForBars(4, 2) == 120)
    #expect(SampleMath.tempoForBars(2, 2) == SampleMath.tempoForBars(2, 1) * 2)
    #expect(SampleMath.tempoForBars(0, 1) == 0)
    #expect(SampleMath.tempoForBars(-1, 1) == 0)
    #expect(SampleMath.guessBars(1.3793, tempo: 174) == 1)
    #expect(SampleMath.guessBars(2.7586, tempo: 174) == 2)
    #expect(SampleMath.guessBars(4, tempo: 120) == 2)
    #expect(SampleMath.guessBars(5.5172, tempo: 174) == 4)
    #expect(SampleMath.guessBars(11.03, tempo: 174) == 8)
    // By ratio: a bar and a half at 174 is nearer two bars than one.
    #expect(SampleMath.guessBars(1.5 * 240 / 174, tempo: 174) == 2)
    for seconds in [0.0, -3, 0.001, 1e6] { #expect([1, 2, 4, 8].contains(SampleMath.guessBars(seconds))) }
  }

  @Test func aFileIsMadeMonoLoudAndDrawn() {
    #expect(SampleMath.toMono([[1, 0.5, 0], [1, 0.5, 0]]) == [1, 0.5, 0])
    #expect(SampleMath.toMono([[1, 0, 0], [1, 1, 0]]) == [1, 0.5, 0])
    #expect(SampleMath.toMono([[0.2, -0.4]]) == [0.2, -0.4])
    #expect(SampleMath.toMono([]).isEmpty)
    let loud = SampleMath.normalise([0.1, -0.5, 0.25])
    #expect(abs(loud.map { abs($0) }.max()! - 0.9) < 1e-6)
    #expect(SampleMath.normalise([0, 0]) == [0, 0])
    #expect(
      SampleMath.waveformPeaks([0, 0.25, -0.5, 0, 1, 0.5, 0, -0.25], buckets: 4) == [0.25, 0.5, 1, 0.25])
    #expect(SampleMath.waveformPeaks([], buckets: 3) == [0, 0, 0])
    #expect(SampleMath.name("Amen Brother.wav") == "Amen Brother")
    #expect(SampleMath.name(".wav") == "sample")
    #expect(SampleMath.name(String(repeating: "x", count: 80) + ".aif").count == 60)
  }

  @Test func theBreaksAreTheReferences() throws {
    #expect(RackBreak.barFrames(174, 44100) == 60828)
    #expect(RackBreak.barFrames(174, 48000) == 66207)
    #expect(RackBreak.barFrames(120, 44100) == 88200)
    #expect(RackBreak.steps("X... x.x.") == [.accent, .off, .off, .off, .on, .off, .on, .off])
    for entry in RackBreak.all {
      #expect(entry.tempo >= 160 && entry.tempo <= 180)
      for (voice, line) in entry.tracks {
        #expect(voice.hasPrefix("909."))
        #expect(RackBreak.steps(line).count == 16)
      }
      let audio = entry.render(sampleRate: 48000)
      #expect(audio.count == RackBreak.barFrames(entry.tempo, 48000))
      #expect(abs(audio.map { abs($0) }.max()! - 0.9) < 1e-5, "\(entry.id)")
    }
  }
}
