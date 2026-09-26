/// What is on screen, as a screen reader is told it: each control's role, its name, what it is set
/// to and where it is, in a tree, whose ids last from one frame to the next so that a control keeps
/// being the same control. A platform's window hands it to the platform's own accessibility — UI
/// Automation on Windows — and hands back what a screen reader asks to be done.
public struct AccessibilityNode: Equatable, Sendable {
  public enum Role: Int32, Sendable {
    /// Holds others: a panel, a lane, a line of steps.
    case group = 0
    /// Does something when pressed.
    case button = 1
    /// On or off, and turned over when pressed.
    case toggle = 2
    /// A value in a range, set or stepped: a knob, a number.
    case slider = 3
    /// Words, and nothing to do with them.
    case text = 4
  }

  /// Which it is, lasting from frame to frame: `tempo`, `lane.909.bd.step.3`.
  public var id: String
  public var role: Role
  public var name: String
  /// What it is set to, as a person would say it: "128 BPM", "accent".
  public var value: String?
  /// A slider's range and where it is in it, and a step for turning it a notch.
  public var range: ClosedRange<Double>?
  public var current: Double?
  public var step: Double?
  /// A toggle's state.
  public var isOn: Bool?
  /// Where it is, in points from the window's top left: x, y, width and height.
  public var frame: SIMD4<Float>
  public var children: [AccessibilityNode]

  public init(
    id: String, role: Role, name: String, value: String? = nil, range: ClosedRange<Double>? = nil,
    current: Double? = nil, step: Double? = nil, isOn: Bool? = nil, frame: SIMD4<Float> = .zero,
    children: [AccessibilityNode] = []
  ) {
    self.id = id
    self.role = role
    self.name = name
    self.value = value
    self.range = range
    self.current = current
    self.step = step
    self.isOn = isOn
    self.frame = frame
    self.children = children
  }

  /// This and everything under it, each before what it holds.
  public var flattened: [AccessibilityNode] { [self] + children.flatMap(\.flattened) }

  /// The node with `id`, here or under here.
  public func node(_ id: String) -> AccessibilityNode? {
    if self.id == id { return self }
    for child in children {
      if let found = child.node(id) { return found }
    }
    return nil
  }
}

/// What a screen reader asks be done to a control, by its id.
public enum AccessibilityAction: Sendable, Equatable {
  /// A button pressed, or a toggle turned over.
  case press(String)
  /// A slider set to a value in its range.
  case set(String, Double)
  /// A slider turned a notch up or down.
  case increment(String)
  case decrement(String)
}
