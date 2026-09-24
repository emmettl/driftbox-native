import DriftboxShell
import Testing

/// The platform-neutral half of the shell: what a menu is, and how a shortcut is written.
struct ShellTests {
  @Test func shortcutsAreWrittenAsWindowsWritesThem() {
    #expect(Shortcut("s", [.control]).label == "Ctrl+S")
    #expect(Shortcut("s", [.control, .shift]).label == "Ctrl+Shift+S")
    #expect(Shortcut(.space, []).label == "Space")
    #expect(Shortcut(.function(5), [.option]).label == "Alt+F5")
    #expect(Shortcut(.return, [.control]).label == "Ctrl+Enter")
  }

  /// A shortcut written for every platform is held with the one each platform holds shortcuts with.
  @Test func thePrimaryModifierIsThePlatforms() {
    #if os(macOS) || os(iOS)
      #expect(Modifiers.primary == .command)
    #else
      #expect(Modifiers.primary == .control)
      #expect(Shortcut("o").label == "Ctrl+O")
    #endif
  }

  @Test func commandsAreFoundInOrderAtAnyDepth() {
    let bar = MenuBar([
      Menu(
        "File",
        [.command("Open…", id: "open"), .separator, .submenu(Menu("Recent", [.command("A", id: "a")]))]),
      Menu("Transport", [.command("Play", id: "play")]),
    ])
    #expect(bar.commands.map(\.id) == ["open", "a", "play"])
  }
}

#if os(Windows)
  import Foundation
  import WinSDK
  @testable import DriftboxWin32

  /// Windows' half, against a window that is never shown and the messages Windows would send it.
  @MainActor
  struct Win32ShellTests {
    final class Heard {
      var events: [ShellEvent] = []
    }

    func window() throws -> (Win32Window, Heard) {
      let window = try Win32Window(title: "Driftbox test", width: 320, height: 200, visible: false)
      let heard = Heard()
      window.onEvent = { heard.events.append($0) }
      return (window, heard)
    }

    static func lParam(_ x: Int, _ y: Int) -> LPARAM { LPARAM(x & 0xFFFF | (y & 0xFFFF) << 16) }

    @Test func keysAreNamedOrKnownByWhatTheyType() {
      #expect(Win32Input.namedKey(VK_SPACE) == .space)
      #expect(Win32Input.namedKey(VK_F5) == .function(5))
      #expect(Win32Input.namedKey(0x41) == nil)
      let scan = MapVirtualKeyW(0x41, 0)
      #expect(Win32Input.character(virtualKey: 0x41, scanCode: scan, shift: false) == "a")
      #expect(Win32Input.character(virtualKey: 0x41, scanCode: scan, shift: true) == "A")
      // Held down long enough to repeat: bit 30 of the key message.
      let repeating = Win32Input.key(
        virtualKey: WPARAM(VK_SPACE), lParam: 1 << 30, isDown: true, modifiers: [])
      #expect(repeating == KeyEvent(key: .space, isDown: true, isRepeat: true))
      #expect(Win32Input.virtualKey(.character("o")) == 0x4F)
      #expect(Win32Input.virtualKey(.function(12)) == VK_F12)
    }

    @Test func shortcutsBecomeAcceleratorsAndLabels() {
      let commands = [
        MenuItem.Command("Open…", id: "open", shortcut: Shortcut("o", [.control])),
        MenuItem.Command("Play", id: "play", shortcut: Shortcut(.space, [])),
        MenuItem.Command("Save As…", id: "saveAs", shortcut: Shortcut("s", [.control, .shift])),
        MenuItem.Command("About", id: "about"),
      ]
      let accelerators = Win32Menus.accelerators(for: commands)
      #expect(accelerators.count == 3)
      #expect(accelerators[0].key == 0x4F && accelerators[0].cmd == 100)
      #expect(accelerators[0].fVirt == BYTE(FVIRTKEY) | BYTE(FCONTROL))
      #expect(accelerators[1].key == WORD(VK_SPACE) && accelerators[1].fVirt == BYTE(FVIRTKEY))
      #expect(
        accelerators[2].fVirt == BYTE(FVIRTKEY) | BYTE(FCONTROL) | BYTE(FSHIFT) && accelerators[2].cmd == 102)
      #expect(Win32Menus.label(for: commands[0]) == "Open…\tCtrl+O")
      #expect(Win32Menus.label(for: commands[3]) == "About")
      #expect(Win32Menus.mnemonic("File") == "&File")
    }

    @Test func aPanelIsOfferedEveryEndingOfAType() {
      let filter = Win32Files.filter(for: [
        FileType(name: "Driftbox Song", extensions: ["driftbox", "song.json"])
      ])
      let expected = "Driftbox Song (*.driftbox;*.song.json)\0*.driftbox;*.song.json\0\0"
      #expect(String(decoding: filter, as: UTF16.self) == expected)
    }

    /// A mouse press, drag and release is one pointer, in points, from the window's top left.
    @Test func theMouseIsAPointer() throws {
      let (window, heard) = try window()
      defer { window.close() }
      SendMessageW(window.handle, UINT(WM_LBUTTONDOWN), 0, Self.lParam(30, 20))
      SendMessageW(window.handle, UINT(WM_MOUSEMOVE), 0, Self.lParam(60, 40))
      SendMessageW(window.handle, UINT(WM_LBUTTONUP), 0, Self.lParam(60, 40))
      let pointers = heard.events.compactMap { event -> PointerEvent? in
        if case .pointer(let pointer) = event { pointer } else { nil }
      }
      #expect(pointers.map(\.phase) == [.began, .moved, .ended])
      #expect(pointers.allSatisfy { $0.kind == .mouse && $0.id == 0 && $0.button == 0 })
      #expect(pointers[0].location == SIMD2(30, 20) / window.scale)
      #expect(pointers[2].location == SIMD2(60, 40) / window.scale)
    }

    @Test func keysAndTheWheelArrive() throws {
      let (window, heard) = try window()
      defer { window.close() }
      SendMessageW(window.handle, UINT(WM_KEYDOWN), WPARAM(VK_SPACE), 0)
      SendMessageW(window.handle, UINT(WM_KEYUP), WPARAM(VK_SPACE), 0)
      SendMessageW(window.handle, UINT(WM_KEYDOWN), 0x41, LPARAM(MapVirtualKeyW(0x41, 0)) << 16)
      var inside = POINT(x: 10, y: 10)
      ClientToScreen(window.handle, &inside)
      SendMessageW(
        window.handle, UINT(WM_MOUSEWHEEL), WPARAM(120) << 16, Self.lParam(Int(inside.x), Int(inside.y)))
      #expect(heard.events.count == 4)
      #expect(heard.events[0] == .key(KeyEvent(key: .space)))
      #expect(heard.events[1] == .key(KeyEvent(key: .space, isDown: false)))
      #expect(heard.events[2] == .key(KeyEvent(key: .character("a"))))
      #expect(
        heard.events[3]
          == .scroll(
            ScrollEvent(location: SIMD2(10, 10) / window.scale, delta: SIMD2(0, -Win32Input.pointsPerNotch))))
    }

    /// A command arrives by its id, unless it is not enabled now, and its menu greys it as it opens.
    @Test func commandsArriveWhileEnabledAndGreyWhenNot() throws {
      let (window, heard) = try window()
      defer { window.close() }
      var saving = false
      window.isEnabled = { $0 != "save" || saving }
      window.menuBar = MenuBar([
        Menu("File", [.command("Open…", id: "open", shortcut: Shortcut("o")), .command("Save", id: "save")])
      ])
      // The menu bar takes its height from the drawing area, which says so as a resize: only the
      // commands matter here.
      var commands: [ShellEvent] { heard.events.filter { if case .command = $0 { true } else { false } } }
      SendMessageW(window.handle, UINT(WM_COMMAND), 100, 0)
      SendMessageW(window.handle, UINT(WM_COMMAND), 101, 0)
      #expect(commands == [.command("open")])
      saving = true
      SendMessageW(window.handle, UINT(WM_COMMAND), 101, 0)
      #expect(commands == [.command("open"), .command("save")])
      #expect(heard.events.contains { if case .resized = $0 { true } else { false } })

      let file = GetSubMenu(GetMenu(window.handle), 0)
      saving = false
      SendMessageW(window.handle, UINT(WM_INITMENUPOPUP), WPARAM(UInt(bitPattern: file)), 0)
      #expect(GetMenuState(file, 101, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) != 0)
      #expect(GetMenuState(file, 100, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) == 0)
    }

    /// A menu ticks what `isChecked` says is on as it opens, and unticks it again when it is not.
    @Test func settingsAreTickedAsTheirMenuOpens() throws {
      let (window, _) = try window()
      defer { window.close() }
      var metronome = true
      window.isChecked = { $0 == "metronome" && metronome }
      window.menuBar = MenuBar([
        Menu("Transport", [.command("Metronome", id: "metronome"), .command("Count In", id: "countIn")])
      ])
      let transport = GetSubMenu(GetMenu(window.handle), 0)
      SendMessageW(window.handle, UINT(WM_INITMENUPOPUP), WPARAM(UInt(bitPattern: transport)), 0)
      #expect(GetMenuState(transport, 100, UINT(MF_BYCOMMAND)) & UINT(MF_CHECKED) != 0)
      #expect(GetMenuState(transport, 101, UINT(MF_BYCOMMAND)) & UINT(MF_CHECKED) == 0)
      metronome = false
      SendMessageW(window.handle, UINT(WM_INITMENUPOPUP), WPARAM(UInt(bitPattern: transport)), 0)
      #expect(GetMenuState(transport, 100, UINT(MF_BYCOMMAND)) & UINT(MF_CHECKED) == 0)
    }

    /// Closed by whoever is using it, the window asks first, and stays open if the answer is no;
    /// closed by the app, it does not ask.
    @Test func closingAsksFirst() throws {
      let (window, _) = try window()
      var asked = 0
      var answer = false
      window.shouldClose = {
        asked += 1
        return answer
      }
      SendMessageW(window.handle, UINT(WM_CLOSE), 0, 0)
      #expect(asked == 1)
      #expect(window.isOpen, "kept open")
      answer = true
      SendMessageW(window.handle, UINT(WM_CLOSE), 0, 0)
      #expect(asked == 2)
      #expect(!window.isOpen, "and closed once allowed")

      let (other, _) = try self.window()
      other.shouldClose = {
        asked += 1
        return false
      }
      other.close()
      #expect(asked == 2, "the app closing it is not asked")
      #expect(!other.isOpen)
    }

    /// A shortcut pressed arrives as its command, through the window's own queue as a key would.
    @Test func aShortcutArrivesAsItsCommand() throws {
      let (window, heard) = try window()
      defer { window.close() }
      window.menuBar = MenuBar([
        Menu("Transport", [.command("Play or Stop", id: "toggle", shortcut: Shortcut(.space, []))])
      ])
      PostMessageW(window.handle, UINT(WM_KEYDOWN), WPARAM(VK_SPACE), 0x39_0001)
      window.pump()
      #expect(heard.events.contains(.command("toggle")))
    }

    /// Work posted from another thread runs on the window's, in its loop; and once the window has
    /// gone, nothing posted runs at all.
    /// Synchronous, and posted from a thread of its own, because a window's messages are the thread's
    /// that made it, and an `await` here could come back on another.
    @Test func workPostedFromAnyThreadRunsInTheWindowsLoop() throws {
      let (window, _) = try window()
      final class Ran: @unchecked Sendable { var count = 0 }
      let ran = Ran()
      let posted = DispatchSemaphore(value: 0)
      Thread { [mailbox = window] in
        mailbox.post { ran.count += 1 }
        posted.signal()
      }.start()
      posted.wait()
      #expect(ran.count == 0)
      window.pump()
      #expect(ran.count == 1)
      window.close()
      window.post { ran.count += 1 }
      window.pump()
      #expect(ran.count == 1)
    }

    /// While Windows holds the loop to move or resize the window, frames still come, from its timer.
    @Test func framesComeWhileTheWindowIsResized() throws {
      let (window, _) = try window()
      var frames = 0
      var framesWhileResizing = 0
      try window.run {
        frames += 1
        if window.isResizing { framesWhileResizing += 1 }
        if frames == 1 {
          PostMessageW(window.handle, UINT(WM_ENTERSIZEMOVE), 0, 0)
          PostMessageW(window.handle, UINT(WM_TIMER), 1, 0)
          PostMessageW(window.handle, UINT(WM_EXITSIZEMOVE), 0, 0)
        }
        if frames >= 4 { window.close() }
      }
      #expect(framesWhileResizing >= 1)
      #expect(!window.isResizing)
      #expect(!window.isOpen)
    }

    /// A context menu is made greyed and ticked as it is asked, its commands numbered past any menu
    /// bar's, in the order they come, submenus and all.
    @Test func aContextMenuIsMadeGreyedAndTicked() throws {
      let menu = Menu(
        "Lane",
        [
          .command("Copy", id: "copy"), .command("Paste", id: "paste"), .separator,
          .submenu(Menu("Length", [.command("8", id: "8"), .command("16", id: "16")])),
        ])
      let (popup, commands) = Win32Menus.popUp(menu, isEnabled: { $0 != "paste" }, isChecked: { $0 == "16" })
      defer { DestroyMenu(popup) }
      #expect(commands.map(\.id) == ["copy", "paste", "8", "16"])
      let first = UINT(Win32Menus.popUpFirstID)
      #expect(Win32Menus.popUpFirstID > Win32Menus.firstID + 1000, "clear of any menu bar's")
      #expect(GetMenuState(popup, first, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) == 0)
      #expect(GetMenuState(popup, first + 1, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) != 0)
      let inner = try #require(GetSubMenu(popup, 3))
      #expect(GetMenuState(inner, first + 3, UINT(MF_BYCOMMAND)) & UINT(MF_CHECKED) != 0)
      #expect(GetMenuState(inner, first + 2, UINT(MF_BYCOMMAND)) & UINT(MF_CHECKED) == 0)
    }

    /// A shortcut with no Ctrl or Alt is a shortcut until the app takes text; then its key is
    /// typed, and arrives as a key.
    @Test func typedTextIsNotTakenForAShortcut() throws {
      let (window, heard) = try window()
      defer { window.close() }
      window.menuBar = MenuBar([
        Menu("Transport", [.command("Play", id: "play", shortcut: Shortcut(.space, []))])
      ])
      func press() {
        heard.events.removeAll()
        PostMessageW(window.handle, UINT(WM_KEYDOWN), WPARAM(VK_SPACE), 0)
        window.pump()
      }
      press()
      #expect(heard.events.contains(.command("play")))
      window.takesText = true
      press()
      #expect(heard.events.contains(.key(KeyEvent(key: .space))))
      #expect(!heard.events.contains(.command("play")))
    }

    struct Broken: Error {}

    @Test func aFramesErrorEndsTheLoop() throws {
      let (window, _) = try window()
      defer { window.close() }
      #expect(throws: Broken.self) { try window.run { throw Broken() } }
    }

    /// Registering a type writes what an installer would: the ending to the program's name for it,
    /// the program's own icon, and the program to open it with, the file's path quoted after it.
    /// What would be written, only: a test has no business in the machine's registry.
    @Test func aFileTypeIsTheProgramsAsAnInstallerWritesIt() {
      let songs = Win32FileType(fileExtension: ".driftbox", progID: "Driftbox.Song", name: "Driftbox Song")
      let values = songs.values(executable: #"C:\Program Files\Driftbox\Driftbox.exe"#)
      #expect(
        values.map(\.key) == [
          ".driftbox", "Driftbox.Song", #"Driftbox.Song\DefaultIcon"#, #"Driftbox.Song\shell\open\command"#,
        ])
      #expect(values.allSatisfy { $0.name == nil }, "every one the key's default")
      #expect(values[0].data == "Driftbox.Song")
      #expect(values[1].data == "Driftbox Song")
      #expect(values[2].data == #""C:\Program Files\Driftbox\Driftbox.exe",0"#)
      #expect(values[3].data == #""C:\Program Files\Driftbox\Driftbox.exe" "%1""#)
    }
  }
#endif
