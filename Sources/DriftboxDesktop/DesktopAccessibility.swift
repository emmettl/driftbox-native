import DriftboxShell

/// What is on screen, told to screen readers: the groovebox's controls, or the rack's, as their
/// interfaces describe them, as they are now, a few times a second while something is reading the
/// window — and not at all while nothing is.
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
    let rack = showsRack ? rackInterface : nil
    window.describe(rack?.accessibility ?? interface.accessibility)
  }
}
