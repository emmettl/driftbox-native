/// Undo and redo for a value that is replaced whole by every edit, which a song is: each edit is
/// the value before, the value after, and what to call the change — "Undo Set Step", not "Undo".
///
/// Foundation's `UndoManager` is the Mac's way of doing this and is not there on Windows; and for
/// a value this is all it needs to be. Nothing here runs the edit: undoing hands back the value to
/// go back to, and whoever holds the value puts it back.
public struct UndoHistory<Value> {
  public struct Change {
    public var name: String
    public var before: Value
    public var after: Value
  }

  /// How many edits are kept to go back through. A song is small, and shares what an edit does
  /// not touch with the song before it, so this many cost little.
  public var limit: Int

  private var done: [Change] = []
  private var undone: [Change] = []

  public init(limit: Int = 500) {
    self.limit = limit
  }

  public var canUndo: Bool { !done.isEmpty }
  public var canRedo: Bool { !undone.isEmpty }
  /// What the Edit menu offers: "Undo" and the name of the edit it would undo.
  public var undoTitle: String { done.last.map { "Undo \($0.name)" } ?? "Undo" }
  public var redoTitle: String { undone.last.map { "Redo \($0.name)" } ?? "Redo" }

  /// An edit made: `before` became `after`. Whatever had been undone can no longer be redone,
  /// since the edit has gone somewhere else from here.
  public mutating func record(_ name: String, before: Value, after: Value) {
    done.append(Change(name: name, before: before, after: after))
    if done.count > limit { done.removeFirst(done.count - limit) }
    undone.removeAll()
  }

  /// The value to go back to, or nil when there is nothing to undo.
  public mutating func undo() -> Value? {
    guard let change = done.popLast() else { return nil }
    undone.append(change)
    return change.before
  }

  /// The value to go forward to again, or nil when there is nothing to redo.
  public mutating func redo() -> Value? {
    guard let change = undone.popLast() else { return nil }
    done.append(change)
    return change.after
  }

  /// Forget everything: a different value has arrived, and its history is not this one's.
  public mutating func clear() {
    done.removeAll()
    undone.removeAll()
  }
}
