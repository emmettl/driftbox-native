import DriftboxDSP
import Testing

struct ParamTimelineTests {
  @Test func holdsItsDefaultUntilTheFirstEvent() {
    var timeline = ParamTimeline(defaultValue: 3)
    timeline.setValue(5, at: 1)
    #expect(timeline.value(at: 0.5) == 3)
    #expect(timeline.value(at: 1) == 5)
    #expect(timeline.value(at: 9) == 5)
  }

  @Test func rampsRunFromTheEventBeforeThem() {
    var timeline = ParamTimeline(defaultValue: 0)
    timeline.setValue(2, at: 1)
    timeline.linearRamp(to: 4, at: 3)
    timeline.exponentialRamp(to: 1, at: 5)
    #expect(timeline.value(at: 2) == 3)
    #expect(timeline.value(at: 3) == 4)
    #expect(timeline.value(at: 4) == 2)  // halfway from 4 to 1 by ratio
    #expect(timeline.value(at: 6) == 1)
  }

  @Test func anExponentialRampThatWouldTouchZeroHoldsInstead() {
    var timeline = ParamTimeline(defaultValue: 0)
    timeline.setValue(0, at: 0)
    timeline.exponentialRamp(to: 1, at: 2)
    #expect(timeline.value(at: 1) == 0)
    #expect(timeline.value(at: 2) == 1)
  }

  @Test func aTargetApproachesByItsTimeConstantUntilSomethingElseTakesOver() {
    var timeline = ParamTimeline(defaultValue: 1)
    timeline.setTarget(0, at: 0, timeConstant: 1)
    timeline.setValue(5, at: 3)
    #expect(abs(timeline.value(at: 1) - 0.36787944117144233) < 1e-15)
    #expect(abs(timeline.value(at: 2) - 0.1353352832366127) < 1e-15)
    #expect(timeline.value(at: 3) == 5)
  }

  /// Cancelling before anything has played simply forgets.
  @Test func cancellingUpFrontForgetsARampWhole() {
    var timeline = ParamTimeline(defaultValue: 0)
    timeline.setValue(8, at: 0)
    timeline.linearRamp(to: 0, at: 4)
    timeline.cancel(from: 2)
    #expect(timeline.value(at: 1) == 8)
    #expect(timeline.value(at: 3) == 8)
  }

  /// Cancelling part-way keeps what was played and then snaps back to where the ramp began —
  /// measured against the browser, which does not hold where the ramp had got to.
  @Test func cancellingPartWayKeepsWhatWasPlayedThenSnapsBack() {
    var timeline = ParamTimeline(defaultValue: 0)
    timeline.setValue(8, at: 0)
    timeline.linearRamp(to: 0, at: 4)
    timeline.cancel(from: 3, lastRendered: 2)
    #expect(timeline.value(at: 1) == 6)
    #expect(timeline.value(at: 2) == 4)
    #expect(timeline.value(at: 2.5) == 8)
    timeline.setValue(1, at: 3)
    #expect(timeline.value(at: 3) == 1)
  }

  @Test func cancellingLeavesEarlierEventsAlone() {
    var timeline = ParamTimeline(defaultValue: 0)
    timeline.setValue(1, at: 1)
    timeline.setValue(2, at: 2)
    timeline.setValue(3, at: 3)
    timeline.cancel(from: 2, lastRendered: 1.5)
    #expect(timeline.value(at: 1.5) == 1)
    #expect(timeline.value(at: 5) == 1)
  }
}
