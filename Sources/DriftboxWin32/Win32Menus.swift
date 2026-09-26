#if os(Windows)
  import DriftboxShell
  import WinSDK

  /// A `MenuBar` as a Win32 menu and an accelerator table. Commands are numbered in the order they
  /// appear, from `firstID`, and the number is what `WM_COMMAND` brings back.
  final class Win32Menus {
    static let firstID = 100
    let menu: HMENU
    let accelerators: HACCEL?
    let commands: [MenuItem.Command]

    init(_ bar: MenuBar) {
      commands = bar.commands
      menu = CreateMenu()
      for top in bar.menus {
        let popup = Self.build(top, numbering: commands)
        Self.append(menu, title: Self.mnemonic(top.title), popup: popup)
      }
      var table = Self.accelerators(for: commands)
      accelerators = table.isEmpty ? nil : CreateAcceleratorTableW(&table, Int32(table.count))
    }

    deinit {
      if let accelerators { DestroyAcceleratorTable(accelerators) }
      // A menu set on a window is let go of with it; one replaced is let go of here.
      DestroyMenu(menu)
    }

    /// The command numbered `id`, if it is one of these.
    func command(_ id: Int) -> MenuItem.Command? {
      let index = id - Self.firstID
      return commands.indices.contains(index) ? commands[index] : nil
    }

    /// Every item in `popup` greyed or not as `isEnabled` says, and ticked or not as `isChecked`
    /// does, as it opens.
    func refresh(_ popup: HMENU, isEnabled: (String) -> Bool, isChecked: (String) -> Bool) {
      for position in 0..<max(0, GetMenuItemCount(popup)) {
        let id = Int(GetMenuItemID(popup, position))
        guard let command = command(id) else { continue }
        let state = isEnabled(command.id) ? MF_ENABLED : MF_GRAYED
        EnableMenuItem(popup, UINT(id), UINT(MF_BYCOMMAND) | UINT(state))
        let tick = isChecked(command.id) ? MF_CHECKED : MF_UNCHECKED
        CheckMenuItem(popup, UINT(id), UINT(MF_BYCOMMAND) | UINT(tick))
      }
    }

    // MARK: - A menu of its own

    /// Where a context menu's commands are numbered from: past any menu bar's, so that nothing
    /// meant for the one is taken for the other.
    static let popUpFirstID = 30000

    /// `menu` as a context menu, each item greyed and ticked as it is now, and its commands in the
    /// order they are numbered from `popUpFirstID`. The caller destroys the menu.
    static func popUp(
      _ menu: Menu, isEnabled: (String) -> Bool, isChecked: (String) -> Bool
    ) -> (menu: HMENU, commands: [MenuItem.Command]) {
      let commands = menu.commands
      let popup = build(menu, numbering: commands, from: popUpFirstID)
      func mark(_ popup: HMENU) {
        for position in 0..<max(0, GetMenuItemCount(popup)) {
          if let inner = GetSubMenu(popup, position) {
            mark(inner)
            continue
          }
          let id = Int(GetMenuItemID(popup, position))
          let index = id - popUpFirstID
          guard commands.indices.contains(index) else { continue }
          let state = isEnabled(commands[index].id) ? MF_ENABLED : MF_GRAYED
          EnableMenuItem(popup, UINT(id), UINT(MF_BYCOMMAND) | UINT(state))
          let tick = isChecked(commands[index].id) ? MF_CHECKED : MF_UNCHECKED
          CheckMenuItem(popup, UINT(id), UINT(MF_BYCOMMAND) | UINT(tick))
        }
      }
      mark(popup)
      return (popup, commands)
    }

    // MARK: - Building

    private static func build(_ menu: Menu, numbering: [MenuItem.Command], from first: Int = firstID) -> HMENU
    {
      let popup = CreatePopupMenu()!
      for item in menu.items {
        switch item {
        case .command(let command):
          let id = first + (numbering.firstIndex(of: command) ?? 0)
          label(for: command).withCString(encodedAs: UTF16.self) { text in
            _ = AppendMenuW(popup, UINT(MF_STRING), UINT_PTR(id), text)
          }
        case .separator:
          AppendMenuW(popup, UINT(MF_SEPARATOR), 0, nil)
        case .submenu(let inner):
          append(popup, title: plain(inner.title), popup: build(inner, numbering: numbering, from: first))
        }
      }
      return popup
    }

    private static func append(_ parent: HMENU, title: String, popup: HMENU) {
      title.withCString(encodedAs: UTF16.self) { text in
        _ = AppendMenuW(parent, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: popup)), text)
      }
    }

    /// An item's text: its title, then a tab and its shortcut, which Windows sets in a column of
    /// its own on the right.
    static func label(for command: MenuItem.Command) -> String {
      command.shortcut.map { "\(plain(command.title))\t\($0.label)" } ?? plain(command.title)
    }

    /// A top-level title with its first letter marked, so Alt and that letter opens it.
    static func mnemonic(_ title: String) -> String { "&" + plain(title) }

    /// A title as it is written: an ampersand in it, as a song or a device may have, is one, and not
    /// Windows' mark for the letter after it.
    static func plain(_ title: String) -> String { title.replacingOccurrences(of: "&", with: "&&") }

    /// Every command's shortcut as an accelerator, skipping any this keyboard cannot type.
    static func accelerators(for commands: [MenuItem.Command]) -> [ACCEL] {
      commands.enumerated().compactMap { index, command in
        guard let shortcut = command.shortcut, let virtualKey = Win32Input.virtualKey(shortcut.key) else {
          return nil
        }
        var flags = BYTE(FVIRTKEY)
        if shortcut.modifiers.contains(.control) { flags |= BYTE(FCONTROL) }
        if shortcut.modifiers.contains(.shift) { flags |= BYTE(FSHIFT) }
        if shortcut.modifiers.contains(.option) { flags |= BYTE(FALT) }
        return ACCEL(fVirt: flags, key: WORD(virtualKey), cmd: WORD(firstID + index))
      }
    }
  }
#endif
