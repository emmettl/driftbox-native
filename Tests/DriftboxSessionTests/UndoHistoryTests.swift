import DriftboxSession
import Testing

/// The session's undo, on its own: a value replaced whole by each edit, and what the Edit menu
/// says about it.
struct UndoHistoryTests {
  @Test func anEmptyHistoryHasNothingToUndoOrRedo() {
    var history = UndoHistory<Int>()
    #expect(!history.canUndo)
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo")
    #expect(history.redoTitle == "Redo")
    #expect(history.undo() == nil)
    #expect(history.redo() == nil)
  }

  /// Undo hands back the value before, redo the value after, and the titles name the edit each
  /// would go through.
  @Test func undoAndRedoGoBackAndForwardThroughTheEdits() {
    var history = UndoHistory<Int>()
    history.record("Set Step", before: 0, after: 1)
    history.record("Set Tempo", before: 1, after: 2)
    #expect(history.canUndo)
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo Set Tempo")

    #expect(history.undo() == 1)
    #expect(history.undoTitle == "Undo Set Step")
    #expect(history.redoTitle == "Redo Set Tempo")
    #expect(history.canRedo)

    #expect(history.undo() == 0)
    #expect(!history.canUndo)
    #expect(history.undoTitle == "Undo")
    #expect(history.redoTitle == "Redo Set Step")

    #expect(history.redo() == 1)
    #expect(history.redo() == 2)
    #expect(!history.canRedo)
    #expect(history.redoTitle == "Redo")
    #expect(history.undoTitle == "Undo Set Tempo")
  }

  /// An edit made after an undo goes somewhere else from there, so what was undone cannot come
  /// back.
  @Test func aNewEditForgetsWhatWasUndone() {
    var history = UndoHistory<Int>()
    history.record("Set Step", before: 0, after: 1)
    history.record("Set Tempo", before: 1, after: 2)
    #expect(history.undo() == 1)
    #expect(history.canRedo)

    history.record("Set Swing", before: 1, after: 3)
    #expect(!history.canRedo)
    #expect(history.redoTitle == "Redo")
    #expect(history.redo() == nil)
    #expect(history.undo() == 1)
    #expect(history.undo() == 0)
  }

  /// A different value arriving takes the whole history with it, both ways.
  @Test func clearingForgetsEverything() {
    var history = UndoHistory<Int>()
    history.record("Set Step", before: 0, after: 1)
    history.record("Set Tempo", before: 1, after: 2)
    _ = history.undo()
    history.clear()
    #expect(!history.canUndo)
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo")
    #expect(history.redoTitle == "Redo")
  }

  /// Past the limit, the oldest edits go first; the newest are always there to undo.
  @Test func onlyTheLastEditsUpToTheLimitAreKept() {
    var history = UndoHistory<Int>(limit: 3)
    #expect(UndoHistory<Int>().limit == 500)
    for value in 0..<5 {
      history.record("Edit \(value + 1)", before: value, after: value + 1)
    }
    #expect(history.undoTitle == "Undo Edit 5")
    #expect(history.undo() == 4)
    #expect(history.undo() == 3)
    #expect(history.undo() == 2)
    #expect(!history.canUndo)
    #expect(history.undo() == nil)
    // What was undone is all still there to redo.
    #expect(history.redo() == 3)
    #expect(history.redo() == 4)
    #expect(history.redo() == 5)
  }
}
