import Testing

@testable import DriftboxSeq

/// Writing a point into a lane, as recording does: the reference's `setAutomationPoint` and
/// `clearAutomationLane`, which read back through `automationValue` as the engine plays them.
struct AutomationWriteTests {
  static func song() -> Song {
    let short = Pattern(id: "short", name: "Short", length: 8)
    var song = Song(patterns: [Pattern(id: "p", name: "Pattern 1", length: 16), short])
    song.chain = [ChainStep(pattern: "p"), ChainStep(pattern: "short"), ChainStep(pattern: "p")]
    return song
  }

  /// A lane is made on first use, points are kept in order along the song, and a point at the same
  /// place is replaced rather than doubled.
  @Test func pointsAreWrittenInOrderAndReplaced() {
    let target = AutomationTarget.fx("drive")
    var song = Self.song()
      .settingAutomationPoint(target, bar: 2, index: 4, value: 0.8)
      .settingAutomationPoint(target, bar: 0, index: 0, value: 0.2)
    #expect(song.automation.count == 1)
    #expect(song.automation[0].interpolation == .linear)
    #expect(song.automation[0].points.map { [$0.bar, $0.index] } == [[0, 0], [2, 4]])
    song = song.settingAutomationPoint(target, bar: 2, index: 4, value: 0.5)
    #expect(song.automation[0].points.count == 2)
    #expect(song.automationValue(target, bar: 2, index: 4, fallback: 0) == 0.5)
    #expect(song.automationValue(target, bar: 1, index: 0, fallback: 0) > 0.2, "ramped between them")
  }

  /// A step past the end of its bar lands on the bar's last; a bar before the song, on its first.
  @Test func aPointIsKeptInsideItsBar() {
    let target = AutomationTarget.bpm
    let song = Self.song()
      .settingAutomationPoint(target, bar: 1, index: 12, value: 140, interpolation: .hold)
      .settingAutomationPoint(target, bar: -3, index: -1, value: 100, interpolation: .hold)
    #expect(song.automation[0].points.map { [$0.bar, $0.index] } == [[0, 0], [1, 7]])
    #expect(song.automation[0].interpolation == .hold)
  }

  /// A blank target or a value that is not a number is not a point.
  @Test func nothingIsWrittenForNothing() {
    let song = Self.song()
    #expect(song.settingAutomationPoint("  ", bar: 0, index: 0, value: 1) == song)
    #expect(song.settingAutomationPoint(AutomationTarget.swing, bar: 0, index: 0, value: .nan) == song)
  }

  /// Clearing a lane takes that lane and no other.
  @Test func aLaneIsCleared() {
    let song = Self.song()
      .settingAutomationPoint(AutomationTarget.bpm, bar: 0, index: 0, value: 120, interpolation: .hold)
      .settingAutomationPoint(AutomationTarget.swing, bar: 0, index: 0, value: 0.2)
    let cleared = song.clearingAutomationLane(AutomationTarget.bpm)
    #expect(cleared.automation.map(\.target) == [AutomationTarget.swing])
    #expect(cleared.clearingAutomationLane("nothing") == cleared)
  }
}
