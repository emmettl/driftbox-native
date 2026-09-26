import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// The 303's step entry, as the reference's keys have it: on, a note typed is written at the
/// cursor into the line of the 303 the keys play, and the cursor moves on; a rest pauses the step
/// and a tie holds the one before through it; only while stopped, each one step of undo.
@MainActor
struct StepEntryTests {
  func bass(_ session: Session, _ voiceId: String = "303.a", at step: Int) -> BassStep? {
    session.shownPattern?.bassStep(voiceId, at: step)
  }

  @Test func aNoteIsWrittenAtTheCursorAndItMovesOn() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(length: 4), in: directory)
      session.enterNote(semitone: 7, accent: false)
      #expect(bass(session, at: 0)?.sounds == false, "nothing written while step entry is off")

      session.toggleStepEntry()
      #expect(session.entryStep == 0)
      session.enterNote(semitone: 7, accent: true)
      let written = try #require(bass(session, at: 0))
      #expect(written.note == 19 && written.accent && written.sounds, "a fifth above the line's middle C")
      #expect(session.entryStep == 1)
      #expect(session.undoTitle == "Undo Enter Note")

      // A tie holds the note before through this step, and slides out of it.
      session.enterTie()
      #expect(bass(session, at: 0)?.slide == true && bass(session, at: 1)?.note == 19)
      #expect(session.entryStep == 2)
      // A rest pauses the step and keeps its pitch.
      session.enterRest()
      #expect(bass(session, at: 2)?.sounds == false && session.entryStep == 3)
      // With nothing sounding before it, a tie does nothing and the cursor stays.
      session.enterTie()
      #expect(session.entryStep == 3)
      // Past the end, round to the start.
      session.enterNote(semitone: -12, accent: false)
      #expect(bass(session, at: 3)?.note == 0 && session.entryStep == 0)

      session.undo()
      #expect(bass(session, at: 3)?.sounds == false, "each entry is one step of undo")
    }
  }

  /// It writes into the 303 whose knobs are showing, as the keys play it.
  @Test func itWritesTheShown303() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(length: 4), in: directory)
      #expect(session.keysBass == "303.a")
      session.selectedVoice = "303.b"
      #expect(session.keysBass == "303.b")
      session.toggleStepEntry()
      session.enterNote(semitone: 0, accent: false)
      #expect(bass(session, "303.b", at: 0)?.note == 12)
      #expect(bass(session, "303.a", at: 0)?.sounds == false)
    }
  }

  /// The cursor moves round the pattern either way, starts again on another pattern, and goes
  /// away with step entry off. Playing, nothing is written and the cursor stays where it is.
  @Test func theCursorMovesAndPlayingWritesNothing() throws {
    try withTemporaryDirectory { directory in
      var song = steadySong(length: 4)
      song.patterns.append(DriftboxSeq.Pattern(id: "q", name: "Pattern 2", length: 8))
      let (session, host) = try openedSession(song, in: directory)
      session.toggleStepEntry()
      session.moveEntry(to: -1)
      #expect(session.entryStep == 3)
      session.moveEntry(to: 5)
      #expect(session.entryStep == 1)
      session.editing = "q"
      #expect(session.entryStep == 0)
      session.editing = nil

      session.play()
      renderAudio(host, frames: 4800)
      session.tick()
      session.enterNote(semitone: 3, accent: false)
      #expect(bass(session, at: 0)?.sounds == false && session.entryStep == 0)

      session.toggleStepEntry()
      #expect(session.entryStep == nil)
      session.moveEntry(to: 2)
      #expect(session.entryStep == nil)
    }
  }
}
