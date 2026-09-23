/// What a window hears, in terms that are the same on every platform, for an interface drawn on
/// the GPU layer to answer. Positions are in points from the top left — pixels divided by the
/// window's scale — so that a control is the same size to a finger on any display.
public enum ShellEvent: Sendable, Equatable {
  case key(KeyEvent)
  case pointer(PointerEvent)
  case scroll(ScrollEvent)
  /// The window is a new size, in pixels, at `scale` pixels to a point.
  case resized(width: Int, height: Int, scale: Float)
  /// A menu item, or its shortcut, by the id it was given.
  case command(String)
}

/// A key, pressed or let go. A key that types something is known by what it types, with the
/// modifiers set aside — `a` with shift held is `A`, with control held still `a` — since that is
/// what both a shortcut and the keyboard played as an instrument go by.
public struct KeyEvent: Sendable, Equatable {
  public var key: Key
  public var modifiers: Modifiers
  public var isDown: Bool
  /// Held down long enough to repeat.
  public var isRepeat: Bool

  public init(key: Key, modifiers: Modifiers = [], isDown: Bool = true, isRepeat: Bool = false) {
    self.key = key
    self.modifiers = modifiers
    self.isDown = isDown
    self.isRepeat = isRepeat
  }
}

public enum Key: Sendable, Hashable {
  case character(Character)
  case space
  case `return`
  case escape
  case tab
  case backspace
  case delete
  case left
  case right
  case up
  case down
  case home
  case end
  case pageUp
  case pageDown
  /// F1 is `function(1)`.
  case function(Int)
}

public struct Modifiers: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let shift = Modifiers(rawValue: 1)
  public static let control = Modifiers(rawValue: 2)
  /// Option on the Mac, Alt elsewhere.
  public static let option = Modifiers(rawValue: 4)
  /// Command on the Mac, the Windows key on Windows.
  public static let command = Modifiers(rawValue: 8)

  /// What a shortcut is held with on this platform: Command on the Mac, Control everywhere else.
  /// A menu written with it means Save is ⌘S on the one and Ctrl+S on the other.
  public static var primary: Modifiers {
    #if os(macOS) || os(iOS)
      .command
    #else
      .control
    #endif
  }
}

/// A finger, a pen or a mouse, as one thing: what a drawn interface wants, and what Android and a
/// touch screen on Windows both give. A mouse is pointer zero; each touch has an id of its own for
/// as long as it is down.
public struct PointerEvent: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case began
    case moved
    case ended
    /// Taken away — by the system, or a window losing it — rather than lifted.
    case cancelled
  }

  public enum Kind: Sendable, Equatable {
    case mouse
    case touch
    case pen
  }

  public var phase: Phase
  public var id: Int
  public var kind: Kind
  /// In points, from the window's top left.
  public var location: SIMD2<Float>
  /// Which mouse button — 0 the main one, 1 the secondary — or 0 for a touch or a pen.
  public var button: Int
  public var modifiers: Modifiers

  public init(
    phase: Phase, id: Int = 0, kind: Kind = .mouse, location: SIMD2<Float>, button: Int = 0,
    modifiers: Modifiers = []
  ) {
    self.phase = phase
    self.id = id
    self.kind = kind
    self.location = location
    self.button = button
    self.modifiers = modifiers
  }
}

/// A wheel or a trackpad, in points: positive `y` scrolls content up, as a finger pushing it would.
public struct ScrollEvent: Sendable, Equatable {
  public var location: SIMD2<Float>
  public var delta: SIMD2<Float>

  public init(location: SIMD2<Float>, delta: SIMD2<Float>) {
    self.location = location
    self.delta = delta
  }
}
