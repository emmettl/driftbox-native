import DriftboxDSP
import Testing

/// `FixedTimeline` against `ParamTimeline`: the same values by the same arithmetic, through a
/// run of cancellations that would overflow six slots if nothing were pruned.
struct FixedTimelineTests {
  @Test func agreesWithParamTimelineThroughRepeatedCancellation() {
    let sr = 48000.0
    let base = 2000.0
    var a = ParamTimeline(defaultValue: base)
    var b = FixedTimeline(defaultValue: base)
    let strikes: [Double] = [0.4, 0.71, 1.02, 1.1, 1.8, 2.41]
    var next = 0
    var differences = 0
    for frame in 0..<130000 {
      let t = Double(frame) / sr
      if next < strikes.count, Int(strikes[next] * sr) / 128 * 128 <= frame {
        let time = Double(Int((strikes[next] * sr).rounded(.up))) / sr
        let last = frame > 0 ? Double(frame - 1) / sr : nil
        a.cancel(from: time, lastRendered: last)
        b.cancel(from: time, lastRendered: last)
        a.setValue(base, at: time)
        b.append(.set, value: base, at: time)
        a.exponentialRamp(to: 30000, at: time + 0.008)
        b.append(.exponentialRamp, value: 30000, at: time + 0.008)
        a.exponentialRamp(to: base, at: time + 0.5)
        b.append(.exponentialRamp, value: base, at: time + 0.5)
        next += 1
      }
      if a.value(at: t) != b.value(at: t) { differences += 1 }
    }
    #expect(differences == 0)
  }

  @Test func convertsFromAParamTimeline() throws {
    var a = ParamTimeline(defaultValue: 0)
    a.setValue(1, at: 0.1)
    a.linearRamp(to: 0.5, at: 0.3)
    a.exponentialRamp(to: 0.0001, at: 0.8)
    let b = try #require(FixedTimeline(a))
    for t in stride(from: 0.0, through: 1.0, by: 0.007) { #expect(a.value(at: t) == b.value(at: t)) }

    var c = ParamTimeline(defaultValue: 0)
    c.setTarget(1, at: 0, timeConstant: 0.1)
    #expect(FixedTimeline(c) == nil)
  }
}
