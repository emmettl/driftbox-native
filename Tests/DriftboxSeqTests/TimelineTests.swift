import ConformanceSupport
import DriftboxDocument
import DriftboxSeq
import Foundation
import Testing

struct TimelineTests {
  /// The timeline is the plan's clock without the plan: every step starts when the plan says it
  /// does, and the pass ends where the last step does.
  @Test(arguments: try Fixtures.songIds())
  func startsEveryStepWhereThePlanDoes(id: String) throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/\(id).song.json")))
    let timeline = Timeline(song: song)
    let plan = song.plan(bars: song.bars)
    #expect(timeline.times.count == plan.count)
    for (time, step) in zip(timeline.times, plan) {
      #expect(abs(time - step.time) < 1e-9)
    }
    let last = try #require(plan.last)
    #expect(abs(timeline.end - (last.time + last.stepSeconds)) < 1e-9)
  }

  /// Quarter notes from the top, moving smoothly through each step rather than jumping at its start.
  @Test func countsTheScoreInQuarterNotes() throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
    let timeline = Timeline(song: song)
    let step = timeline.length(ofStep: 5)
    #expect(timeline.scoreBeat(at: -1) == 0)
    #expect(timeline.scoreBeat(at: 0) == 0)
    #expect(abs(timeline.scoreBeat(at: timeline.times[5] + step / 2)! - 5.5 / 4) < 1e-9)
    #expect(Timeline().scoreBeat(at: 1) == nil)
  }
}
