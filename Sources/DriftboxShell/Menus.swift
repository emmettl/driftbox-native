/// A menu bar as data: what each platform builds its own menus from. An item is a command by id,
/// which arrives as `ShellEvent.command` whether it was chosen or its shortcut pressed, so the app
/// says once what a command does and the platform says how it is reached.
public struct MenuBar: Sendable, Equatable {
  public var menus: [Menu]

  public init(_ menus: [Menu]) { self.menus = menus }

  /// Every command anywhere in it, in order.
  public var commands: [MenuItem.Command] {
    menus.flatMap(\.commands)
  }
}

public struct Menu: Sendable, Equatable {
  public var title: String
  public var items: [MenuItem]

  public init(_ title: String, _ items: [MenuItem]) {
    self.title = title
    self.items = items
  }

  public var commands: [MenuItem.Command] {
    items.flatMap { item -> [MenuItem.Command] in
      switch item {
      case .command(let command): [command]
      case .submenu(let menu): menu.commands
      case .separator: []
      }
    }
  }
}

public enum MenuItem: Sendable, Equatable {
  public struct Command: Sendable, Equatable {
    public var title: String
    public var id: String
    public var shortcut: Shortcut?

    public init(_ title: String, id: String, shortcut: Shortcut? = nil) {
      self.title = title
      self.id = id
      self.shortcut = shortcut
    }
  }

  case command(Command)
  case separator
  case submenu(Menu)

  public static func command(_ title: String, id: String, shortcut: Shortcut? = nil) -> MenuItem {
    .command(Command(title, id: id, shortcut: shortcut))
  }
}

/// A key and what it is held with, as a menu shows it and a keyboard sends it.
public struct Shortcut: Sendable, Hashable {
  public var key: Key
  public var modifiers: Modifiers

  public init(_ key: Key, _ modifiers: Modifiers = .primary) {
    self.key = key
    self.modifiers = modifiers
  }

  /// A letter, digit or symbol with the platform's primary modifier: `Shortcut("s")` is Save.
  public init(_ character: Character, _ modifiers: Modifiers = .primary) {
    self.init(.character(character), modifiers)
  }

  /// As Windows and Android write one beside a menu item: `Ctrl+Shift+S`.
  public var label: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Ctrl") }
    if modifiers.contains(.option) { parts.append("Alt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("Win") }
    parts.append(Self.name(key))
    return parts.joined(separator: "+")
  }

  static func name(_ key: Key) -> String {
    switch key {
    case .character(let character): String(character).uppercased()
    case .space: "Space"
    case .return: "Enter"
    case .escape: "Esc"
    case .tab: "Tab"
    case .backspace: "Backspace"
    case .delete: "Del"
    case .left: "Left"
    case .right: "Right"
    case .up: "Up"
    case .down: "Down"
    case .home: "Home"
    case .end: "End"
    case .pageUp: "PgUp"
    case .pageDown: "PgDn"
    case .function(let number): "F\(number)"
    }
  }
}
