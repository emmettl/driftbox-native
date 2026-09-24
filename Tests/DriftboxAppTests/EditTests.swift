#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import SwiftUI
  import Testing

  @testable import DriftboxApp

  /// The edits the grid and the menus make, through the one door they all go through, and what undo
  /// gives back afterwards.
  @MainActor
  struct EditTests {
    private func opened(_ directory: URL) throws -> (player: Session, manager: Void) {
      let (player, _) = try openedPlayer(steadySong(), in: directory)
      return (player, ())
    }

    /// One gesture's edits. The session's history makes each edit a step of its own, so there is no
    /// grouping to draw by hand; kept so each gesture below still reads as one.
    private func inOneTurn(_: Void, _ body: () -> Void) { body() }

    private func pattern(_ player: Session) throws -> DriftboxSeq.Pattern {
      try #require(player.shownPattern)
    }

    /// In flam mode a click on a 909 step marks a flam; on an 808 lane it still cycles, because
    /// the 808 has no flams.
    @Test func flamModeMarksFlamsOnlyOnThe909() throws {
      try withTemporaryDirectory { directory in
        let (player, manager) = try opened(directory)
        player.flamMode = true
        let pattern = try pattern(player)
        inOneTurn(manager) {
          StepButton(
            player: player, patternId: pattern.id, voiceId: "909.bd", index: 2, value: .on, playing: false
          )
          .cycle()
        }
        #expect(try self.pattern(player).flam("909.bd", at: 2))
        #expect(try self.pattern(player).step("909.bd", at: 2) == .on)
        #expect(player.undoTitle == "Undo Set Flam")

        inOneTurn(manager) {
          player.editShown("Add Lane") {
            var p = $0
            p.tracks["808.cp"] = [StepValue](repeating: .off, count: 16)
            return p
          }
        }
        inOneTurn(manager) {
          StepButton(
            player: player, patternId: pattern.id, voiceId: "808.cp", index: 2, value: .off, playing: false
          )
          .cycle()
        }
        #expect(try self.pattern(player).step("808.cp", at: 2) == .on)
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

  }
#endif
