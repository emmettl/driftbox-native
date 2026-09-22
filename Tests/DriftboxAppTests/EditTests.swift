#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import SwiftUI
  import Testing

  @testable import DriftboxApp

  /// The edits the grid and the menus make, through the one door they all go through, and what undo
  /// gives back afterwards.
  @MainActor
  struct EditTests {
    private func opened(_ directory: URL) throws -> (player: Player, manager: UndoManager) {
      let (player, _) = try openedPlayer(steadySong(), in: directory)
      let manager = UndoManager()
      // Off run loop grouping: closing a group takes a turn of the loop, which leaves a test no say
      // in where the boundaries between its edits fall. They are drawn by hand here instead.
      manager.groupsByEvent = false
      player.undoManager = manager
      return (player, manager)
    }

    /// One edit, in a group of its own, which is what a turn of the run loop would have made of it.
    private func inOneTurn(_ manager: UndoManager, _ body: () -> Void) {
      manager.beginUndoGrouping()
      body()
      manager.endUndoGrouping()
    }

    private func pattern(_ player: Player) throws -> DriftboxSeq.Pattern {
      try #require(player.shownPattern)
    }

    @Test func aStepCyclesOffOnAndAccent() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        @MainActor func cycle() throws {
          let pattern = try pattern(player)
          inOneTurn(manager) {
            StepButton(
              player: player, patternId: pattern.id, voiceId: "909.sd", index: 3,
              value: pattern.step("909.sd", at: 3), playing: false
            ).cycle()
          }
        }

        #expect(try pattern(player).step("909.sd", at: 3) == .off)
        try cycle()
        #expect(try pattern(player).step("909.sd", at: 3) == .on)
        try cycle()
        #expect(try pattern(player).step("909.sd", at: 3) == .accent)
        try cycle()
        #expect(try pattern(player).step("909.sd", at: 3) == .off)
        #expect(player.isEdited)
      }
    }

    @Test func undoGivesBackExactlyWhatWasThere() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        let opened = try #require(player.song)
        #expect(!player.canUndo)
        #expect(player.undoTitle == "Undo")

        let pattern = try pattern(player)
        inOneTurn(manager) {
          StepButton(
            player: player, patternId: pattern.id, voiceId: "909.bd", index: 0, value: .on, playing: false
          ).cycle()
        }
        let once = try #require(player.song)
        #expect(once != opened)
        #expect(player.canUndo)
        // The menu says what it will undo, not merely that it can.
        #expect(player.undoTitle == "Undo Set Step")

        inOneTurn(manager) { player.edit("Set Tempo") { $0.bpm = 128 } }
        #expect(player.undoTitle == "Undo Set Tempo")

        player.undo()
        #expect(player.song == once)
        #expect(player.canRedo)
        #expect(player.redoTitle == "Redo Set Tempo")
        #expect(player.undoTitle == "Undo Set Step")

        player.undo()
        #expect(player.song == opened)
        #expect(!player.canUndo)
        #expect(player.undoTitle == "Undo")

        player.redo()
        #expect(player.song == once)
        #expect(player.canUndo)
      }
    }

    /// Undoing back to the song as it was opened or saved takes the edited mark away again, as
    /// it does in any Mac document: there is nothing to save, so quitting has nothing to ask.
    @Test func undoingBackToTheSavedSongIsNotAnEdit() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        inOneTurn(manager) { player.edit("Set Tempo") { $0.bpm = 128 } }
        inOneTurn(manager) { player.edit("Set Swing") { $0.swing = 0.3 } }
        #expect(player.isEdited)
        player.undo()
        #expect(player.isEdited, "one edit is still there")
        player.undo()
        #expect(!player.isEdited)
        player.redo()
        #expect(player.isEdited)

        // Saved, that is the new unedited song.
        player.save(to: directory.appendingPathComponent("Saved.song.json"))
        #expect(!player.isEdited)
        inOneTurn(manager) { player.edit("Set Tempo") { $0.bpm = 90 } }
        player.undo()
        #expect(!player.isEdited)
      }
    }

    /// A note goes on where it is clicked, and clicking the note that is already there pauses it
    /// rather than moving it.
    @Test func aBassNoteIsSetAndPausedFromTheGrid() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        @MainActor func grid() throws -> BassGrid {
          BassGrid(player: player, pattern: try pattern(player), voiceId: "303.a", playhead: -1)
        }

        inOneTurn(manager) { try? grid().setNote(14, at: 2) }
        var step = try pattern(player).bassStep("303.a", at: 2)
        #expect(step.note == 14)
        #expect(step.sounds)

        inOneTurn(manager) { try? grid().setNote(14, at: 2) }
        step = try pattern(player).bassStep("303.a", at: 2)
        #expect(step.note == 14)
        #expect(!step.sounds)

        inOneTurn(manager) { try? grid().edit(2, "Set Accent") { $0.accent.toggle() } }
        #expect(try pattern(player).bassStep("303.a", at: 2).accent)

        inOneTurn(manager) { try? grid().edit(2, "Set Slide") { $0 = $0.settingSlide(true) } }
        #expect(try pattern(player).bassStep("303.a", at: 2).slide)

        player.undo()
        #expect(!(try pattern(player).bassStep("303.a", at: 2).slide))
      }
    }

    @Test func aLaneMenuChangesOnlyItsOwnLane() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        let before = try #require(player.song)
        let menu = LaneMenu(
          player: player, pattern: try pattern(player), voiceId: "909.bd",
          label: { AnyView(EmptyView()) })

        inOneTurn(manager) { menu.apply("Clear Lane") { $0.clearingTrack("909.bd") } }
        // A lane with no steps at all is a lane that never fires, which is what clearing means.
        let cleared = try pattern(player)
        #expect(cleared.step("909.bd", at: 0) == .off)
        #expect(cleared.tracks["909.bd"] == nil)

        player.undo()
        #expect(player.song == before)
      }
    }

    @Test func aBassMenuRotatesAndTransposesTheLine() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        let grid = BassGrid(player: player, pattern: try pattern(player), voiceId: "303.a", playhead: -1)
        inOneTurn(manager) { grid.setNote(12, at: 0) }
        let menu = BassMenu(player: player, pattern: try pattern(player), voiceId: "303.a")

        inOneTurn(manager) { menu.apply("Transpose") { $0.transposingBassLine("303.a", by: 12) } }
        #expect(try pattern(player).bassStep("303.a", at: 0).note == 24)

        inOneTurn(manager) { menu.apply("Rotate Right") { $0.rotatingBassLine("303.a", by: 1) } }
        #expect(try pattern(player).bassStep("303.a", at: 1).note == 24)
        #expect(player.undoTitle == "Undo Rotate Right")

        player.undo()
        #expect(try pattern(player).bassStep("303.a", at: 0).note == 24)
      }
    }

    /// An edit names itself for the Edit menu, and one that changes nothing still names itself:
    /// what the menu offers is what was done, not what came of it.
    @Test func anEditWithNoSongDoesNothingAtAll() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      player.undoManager = UndoManager()
      player.edit("Set Tempo") { $0.bpm = 200 }
      #expect(player.song == nil)
      #expect(!player.isEdited)
      #expect(!player.canUndo)
      // And undo with nothing to undo is not an error.
      player.undo()
      player.redo()
      #expect(player.undoTitle == "Undo")
      #expect(player.redoTitle == "Redo")
    }

    /// A song arriving in the window takes the old one's undo history with it: those actions are
    /// the other song's.
    @Test func openingASongEmptiesTheUndoHistory() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        inOneTurn(manager) { player.edit("Set Tempo") { $0.bpm = 128 } }
        #expect(player.canUndo)

        player.new()
        #expect(!player.canUndo)
        #expect(!player.canRedo)
        #expect(player.undoTitle == "Undo")
      }
    }

    /// The grid shows the pattern the transport is in unless one has been chosen to edit.
    @Test func theGridFollowsTheTransportUntilAPatternIsChosen() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(changingSong(), in: directory)
        #expect(player.shownPattern?.id == "long")
        player.editing = "short"
        #expect(player.shownPattern?.id == "short")
        #expect(player.usedVoices.map(\.id) == ["909.sd"])
        player.editing = nil
        #expect(player.shownPattern?.id == "long")
        #expect(player.usedVoices.map(\.id) == ["909.bd"])
      }
    }
  }
#endif
