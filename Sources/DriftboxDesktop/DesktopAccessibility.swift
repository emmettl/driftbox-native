import DriftboxShell

/// What is on screen, told to screen readers: the groovebox's controls as the interface describes
/// them, as they are now, a few times a second while something is reading the window — and not at
/// all while nothing is.
extension Desktop {
  /// How often what is on screen is told, at most: often enough that a screen reader hears a step it
  /// set, or where the song has got to, as it changes.
  static let describing = 0.1

  /// Told as of `time`, if something reads the window — or has just `asked` — and it was not told a
  /// moment ago.
  func describe(at time: Double, asked: Bool = false) {
    guard asked || window.isDescribed else { return }
    guard time - describedAt >= Self.describing || time < describedAt else { return }
    describedAt = time
    window.describe(showsRack ? Self.rackUndescribed : interface.accessibility)
  }

  /// The rack, until its modules are described too.
  static let rackUndescribed = AccessibilityNode(
    id: "window", role: .group, name: "",
    children: [
      AccessibilityNode(
        id: "rack", role: .text, name: "The rack",
        value: "Its modules are not described to screen readers yet")
    ])
}
