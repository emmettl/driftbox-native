import DriftboxHost
import DriftboxSeq
import DriftboxSession
import Foundation
import Testing

/// The edits the grid and the menus make, through the one door they all go through, and what undo
/// gives back afterwards.
@MainActor
struct EditTests {
  private func opened(_ directory: URL) throws -> Session {
    try openedSession(steadySong(), in: directory).session
  }

  private func pattern(_ session: Session) throws -> DriftboxSeq.Pattern {
    try #require(session.shownPattern)
  }

  /// The edit a click on a step makes: cycled, under "Set Step".
  private func cycleStep(_ session: Session, _ voiceId: String, at index: Int) throws {
    let pattern = try pattern(session)
    session.editPattern(pattern.id, "Set Step") { $0.cyclingStep(voiceId, at: index) }
  }

  @Test func aStepCyclesOffOnAndAccent() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)

      #expect(try pattern(session).step("909.sd", at: 3) == .off)
      try cycleStep(session, "909.sd", at: 3)
      #expect(try pattern(session).step("909.sd", at: 3) == .on)
      try cycleStep(session, "909.sd", at: 3)
      #expect(try pattern(session).step("909.sd", at: 3) == .accent)
      try cycleStep(session, "909.sd", at: 3)
      #expect(try pattern(session).step("909.sd", at: 3) == .off)
      #expect(session.isEdited)
    }
  }

  @Test func undoGivesBackExactlyWhatWasThere() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      let opened = try #require(session.song)
      #expect(!session.canUndo)
      #expect(session.undoTitle == "Undo")

      try cycleStep(session, "909.bd", at: 0)
      let once = try #require(session.song)
      #expect(once != opened)
      #expect(session.canUndo)
      // The menu says what it will undo, not merely that it can.
      #expect(session.undoTitle == "Undo Set Step")

      session.edit("Set Tempo") { $0.bpm = 128 }
      #expect(session.undoTitle == "Undo Set Tempo")

      session.undo()
      #expect(session.song == once)
      #expect(session.canRedo)
      #expect(session.redoTitle == "Redo Set Tempo")
      #expect(session.undoTitle == "Undo Set Step")

      session.undo()
      #expect(session.song == opened)
      #expect(!session.canUndo)
      #expect(session.undoTitle == "Undo")

      session.redo()
      #expect(session.song == once)
      #expect(session.canUndo)
    }
  }

  /// Undoing back to the song as it was opened or saved takes the edited mark away again, as it
  /// does in any document: there is nothing to save, so quitting has nothing to ask.
  @Test func undoingBackToTheSavedSongIsNotAnEdit() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      session.edit("Set Tempo") { $0.bpm = 128 }
      session.edit("Set Swing") { $0.swing = 0.3 }
      #expect(session.isEdited)
      session.undo()
      #expect(session.isEdited, "one edit is still there")
      session.undo()
      #expect(!session.isEdited)
      session.redo()
      #expect(session.isEdited)

      // Saved, that is the new unedited song.
      session.save(to: directory.appendingPathComponent("Saved.song.json"))
      #expect(!session.isEdited)
      session.edit("Set Tempo") { $0.bpm = 90 }
      session.undo()
      #expect(!session.isEdited)
    }
  }

  /// Copy a lane, paste it into another; a lane will not paste into a line, nor a line into a
  /// lane; cutting leaves the lane empty and undo brings it back.
  @Test func lanesCopyCutAndPaste() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      #expect(!session.canPasteLane(into: "909.sd"))
      session.copyLane("909.bd")
      #expect(session.canPasteLane(into: "909.sd"))
      #expect(!session.canPasteLane(into: "303.a"))
      session.pasteLane(into: "909.sd")
      let pasted = try pattern(session)
      #expect(pasted.tracks["909.sd"] == pasted.tracks["909.bd"])
      #expect(session.undoTitle == "Undo Paste Lane")

      session.cutLane("909.bd")
      #expect(try pattern(session).tracks["909.bd"] == nil)
      session.undo()
      #expect(try pattern(session).tracks["909.bd"] != nil)

      // A line goes into a line.
      session.editShown("Set Note") { $0.settingBassStep("303.a", at: 4, to: BassStep(note: 9)) }
      session.copyLane("303.a")
      #expect(session.canPasteLane(into: "303.b"))
      #expect(!session.canPasteLane(into: "909.sd"))
      session.pasteLane(into: "303.b")
      #expect(try pattern(session).bassStep("303.b", at: 4).note == 9)
    }
  }

  /// The song's sections, edited from the strip's menus.
  @Test func sectionsAreAddedRepeatedMovedAndRemoved() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      let first = try #require(session.song?.patterns.first?.id)
      var added: String?
      session.edit("Add Pattern") { song in
        let result = song.addingPattern()
        song = result.song
        added = result.id
      }
      let second = try #require(added)
      session.edit("Add to Song") { $0 = $0.appendingToChain(second) }
      session.edit("Set Repeat") { $0 = $0.settingChainRepeat(at: 1, to: 4) }
      session.edit("Move Section") { $0 = $0.movingChainEntry(at: 1, by: -1) }
      var chain = try #require(session.song?.chain)
      #expect(chain.map(\.pattern) == [second, first])
      #expect(chain[0].repeat == 4)
      // The transport's arrangement follows: the second pattern is where the song starts.
      #expect(session.song?.pattern(forBar: 0)?.id == second)

      session.edit("Set TR-909 Pattern") { $0 = $0.settingChainClip(at: 0, slot: .tr909, to: first) }
      #expect(session.song?.pattern(forBar: 0, slot: .tr909)?.id == first)

      session.edit("Remove Section") { $0 = $0.removingFromChain(at: 0) }
      chain = try #require(session.song?.chain)
      #expect(chain.map(\.pattern) == [first])
    }
  }

  @Test func aLaneMenuChangesOnlyItsOwnLane() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      let before = try #require(session.song)
      let shown = try pattern(session)

      session.editPattern(shown.id, "Clear Lane") { $0.clearingTrack("909.bd") }
      // A lane with no steps at all is a lane that never fires, which is what clearing means.
      let cleared = try pattern(session)
      #expect(cleared.step("909.bd", at: 0) == .off)
      #expect(cleared.tracks["909.bd"] == nil)

      session.undo()
      #expect(session.song == before)
    }
  }

  @Test func aBassMenuRotatesAndTransposesTheLine() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      let shown = try pattern(session)
      session.editPattern(shown.id, "Set Note") {
        $0.settingBassStep("303.a", at: 0, to: BassStep(note: 12))
      }

      session.editPattern(shown.id, "Transpose") { $0.transposingBassLine("303.a", by: 12) }
      #expect(try pattern(session).bassStep("303.a", at: 0).note == 24)

      session.editPattern(shown.id, "Rotate Right") { $0.rotatingBassLine("303.a", by: 1) }
      #expect(try pattern(session).bassStep("303.a", at: 1).note == 24)
      #expect(session.undoTitle == "Undo Rotate Right")

      session.undo()
      #expect(try pattern(session).bassStep("303.a", at: 0).note == 24)
    }
  }

  /// An edit names itself for the Edit menu, and one that changes nothing still names itself:
  /// what the menu offers is what was done, not what came of it.
  @Test func anEditWithNoSongDoesNothingAtAll() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    session.edit("Set Tempo") { $0.bpm = 200 }
    #expect(session.song == nil)
    #expect(!session.isEdited)
    #expect(!session.canUndo)
    // And undo with nothing to undo is not an error.
    session.undo()
    session.redo()
    #expect(session.undoTitle == "Undo")
    #expect(session.redoTitle == "Redo")
  }

  /// A song arriving in the window takes the old one's undo history with it: those actions are
  /// the other song's.
  @Test func openingASongEmptiesTheUndoHistory() throws {
    try withTemporaryDirectory { directory in
      let session = try opened(directory)
      session.edit("Set Tempo") { $0.bpm = 128 }
      #expect(session.canUndo)

      session.new()
      #expect(!session.canUndo)
      #expect(!session.canRedo)
      #expect(session.undoTitle == "Undo")
    }
  }

  /// The grid shows the pattern the transport is in unless one has been chosen to edit.
  @Test func theGridFollowsTheTransportUntilAPatternIsChosen() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(changingSong(), in: directory)
      #expect(session.shownPattern?.id == "long")
      session.editing = "short"
      #expect(session.shownPattern?.id == "short")
      #expect(session.usedVoices.map(\.id) == ["909.sd"])
      session.editing = nil
      #expect(session.shownPattern?.id == "long")
      #expect(session.usedVoices.map(\.id) == ["909.bd"])
    }
  }
}
