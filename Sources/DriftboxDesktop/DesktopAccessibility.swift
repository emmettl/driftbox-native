import DriftboxCanvas
import DriftboxHost
import DriftboxInterface
import DriftboxShell

/// What is on screen, told to screen readers: the groovebox's controls, or the rack's, as their
/// interfaces describe them, as they are now, a few times a second while something is reading the
/// window — and not at all while nothing is.
///
/// While a screen reader runs, the keyboard moves between the controls, as it does in any Windows
/// program: Tab and Shift+Tab to the next and the one before, Enter to press it, and the arrows to
/// turn a knob or a number a notch. Space still plays and stops. The control the keyboard is on is
/// told to the screen reader, and ringed for anyone looking on.
extension Desktop {
  /// How often what is on screen is told, at most: often enough that a screen reader hears a step it
  /// set, or where the song has got to, as it changes.
  static let describing = 0.1

  /// Whether the keyboard moves between the controls, rather than playing: while a screen reader
  /// runs.
  var keyboardNavigates: Bool { window.screenReaderIsOn }

  /// What is on screen: the rack's controls while it shows, the groovebox's otherwise.
  var described: AccessibilityNode {
    (showsRack ? rackInterface?.accessibility : nil) ?? interface.accessibility
  }

  /// Told as of `time`, if something reads the window — or has just `asked` — and it was not told a
  /// moment ago; and where the keyboard is with it.
  func describe(at time: Double, asked: Bool = false) {
    guard asked || window.isDescribed else { return }
    guard time - describedAt >= Self.describing || time < describedAt else { return }
    describedAt = time
    let root = described
    window.describe(root)
    // The keyboard on a control there is no longer — a panel put away — is on nothing.
    let node = focused.flatMap(root.node).flatMap { Self.focusable($0.role) ? $0 : nil }
    focusFrame = node?.frame
    window.focus(node?.id)
  }

  /// Told now, whenever it was last: what the keyboard did is heard at once.
  func describeNow() {
    describedAt = -.infinity
    describe(at: HostTime.seconds(from: began, to: HostTime.now()), asked: true)
  }

  /// What the keyboard moves between: what can be pressed or set.
  static func focusable(_ role: AccessibilityNode.Role) -> Bool {
    role == .button || role == .toggle || role == .slider
  }

  /// A key, while the keyboard moves between the controls: taken if it moves, presses or turns;
  /// false for any other, and for everything while a name is being typed, which is heard as ever.
  func navigate(_ key: KeyEvent) -> Bool {
    guard key.isDown, keyboardNavigates else { return false }
    let typing = showsRack ? rackInterface?.takesText ?? false : interface.takesText
    guard !typing else { return false }
    switch key.key {
    case .tab:
      guard key.modifiers.subtracting(.shift).isEmpty else { return false }
      let controls = described.flattened.filter { Self.focusable($0.role) }
      guard !controls.isEmpty else {
        // Nothing to move between, with the controls put away: Tab brings them back, as it does
        // without a screen reader.
        if !showsRack, !interface.isShowing { perform(DesktopMenus.controls) }
        describeNow()
        return true
      }
      let back = key.modifiers.contains(.shift)
      let at = focused.flatMap { id in controls.firstIndex { $0.id == id } }
      let next =
        at.map { ($0 + (back ? controls.count - 1 : 1)) % controls.count } ?? (back ? controls.count - 1 : 0)
      focused = controls[next].id
      describeNow()
      return true
    case .return:
      guard key.modifiers.isEmpty, let focused, let node = described.node(focused), Self.focusable(node.role)
      else { return false }
      handle(.accessibility(.press(focused)))
      describeNow()
      return true
    case .up, .right, .down, .left:
      guard key.modifiers.isEmpty, let focused, described.node(focused)?.role == .slider else { return false }
      handle(.accessibility(key.key == .up || key.key == .right ? .increment(focused) : .decrement(focused)))
      describeNow()
      return true
    default:
      return false
    }
  }

  /// A ring round the control the keyboard is on, over the controls drawn on `canvas`, in points.
  func drawFocus(on canvas: Canvas) {
    guard keyboardNavigates, let frame = focusFrame else { return }
    canvas.stroke = Theme.nine
    canvas.lineWidth = 2
    canvas.strokeRoundedRect(frame.x - 3, frame.y - 3, frame.z + 6, frame.w + 6, radius: 6)
  }
}
