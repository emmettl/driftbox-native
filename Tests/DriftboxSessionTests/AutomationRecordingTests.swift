import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// A knob turned: heard as it turns, one step of undo however far it went; and, armed and playing,
/// written into the song's automation at the step the transport is on, as the reference records.
@MainActor
struct AutomationRecordingTests {
  static let drive = AutomationTarget.fx("drive")

  func fourBars() -> Song {
    var song = steadySong()
    song.chain = (0..<4).map { _ in ChainStep(pattern: "p") }
    return song
  }

  func turn(_ session: Session, to value: Double) {
    session.turn("Set Drive", automating: Self.drive, value: value) { $0.fx.drive = value }
  }

  /// Each move is the song's at once; letting go keeps the whole turn as one undo.
  @Test func aTurnIsHeardAndIsOneUndo() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      let before = try #require(session.song).fx.drive
      turn(session, to: 0.3)
      #expect(session.song?.fx.drive == 0.3, "heard as it turns")
      turn(session, to: 0.6)
      #expect(!session.canUndo, "not yet a step of undo")
      session.endTurn()
      #expect(session.undoTitle == "Undo Set Drive")
      session.undo()
      #expect(session.song?.fx.drive == before, "the whole turn, undone at once")
      #expect(!session.canUndo)
    }
  }

  /// Nothing is recorded disarmed, or armed while stopped: there is no step for a point to be on.
  @Test func onlyAnArmedPlayingSongIsRecorded() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(fourBars(), in: directory)
      renderAudio(host, frames: 24000)
      session.tick()
      turn(session, to: 0.4)
      session.endTurn()
      #expect(session.song?.automation.isEmpty == true, "disarmed")

      session.recordsAutomation = true
      session.stop()
      // Stopped once the engine says so, at the next tick, as the app sees it.
      renderAudio(host, frames: 512)
      session.tick()
      #expect(!session.isPlaying)
      turn(session, to: 0.5)
      session.endTurn()
      #expect(session.song?.automation.isEmpty == true, "stopped")
    }
  }

  /// Armed and playing, each move is a point where the transport is, in the lane the knob is, and
  /// the engine plays it back; clearing the automation takes every lane, as one undo.
  @Test func anArmedTurnWritesPointsWhereTheSongIs() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(fourBars(), in: directory)
      session.recordsAutomation = true
      session.seek(toBar: 2)
      session.play()
      renderAudio(host, frames: 12000)
      session.tick()
      let position = try #require(session.position)
      #expect(position.bar == 2)
      turn(session, to: 0.7)
      session.endTurn()

      let lane = try #require(session.song?.automation.first)
      #expect(lane.target == Self.drive && lane.interpolation == .linear)
      #expect(lane.points == [AutomationPoint(bar: 2, index: position.step, value: 0.7)])
      #expect(session.song?.automationValue(Self.drive, bar: 3, index: 0, fallback: 0) == 0.7)

      session.clearAutomation()
      #expect(session.song?.automation.isEmpty == true)
      #expect(session.undoTitle == "Undo Clear Automation")
      session.undo()
      #expect(session.song?.automation.count == 1)
    }
  }
}
