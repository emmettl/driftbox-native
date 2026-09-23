#if os(Windows)
  import DriftboxShell
  import WinSDK

  /// How Windows' keys, buttons and pointers become the shell's events. Pure where it can be, so the
  /// rules can be tested without a keyboard.
  enum Win32Input {
    /// A key that is not a character, by its virtual key code.
    static func namedKey(_ virtualKey: Int32) -> Key? {
      switch virtualKey {
      case VK_SPACE: .space
      case VK_RETURN: .return
      case VK_ESCAPE: .escape
      case VK_TAB: .tab
      case VK_BACK: .backspace
      case VK_DELETE: .delete
      case VK_LEFT: .left
      case VK_RIGHT: .right
      case VK_UP: .up
      case VK_DOWN: .down
      case VK_HOME: .home
      case VK_END: .end
      case VK_PRIOR: .pageUp
      case VK_NEXT: .pageDown
      case VK_F1...VK_F24: .function(Int(virtualKey - VK_F1 + 1))
      default: nil
      }
    }

    /// The virtual key code for a key, for an accelerator: named keys by their own codes, and a
    /// character by the key that types it on this keyboard's layout.
    static func virtualKey(_ key: Key) -> Int32? {
      if case .character(let character) = key {
        guard let unit = String(character).utf16.first, String(character).utf16.count == 1 else { return nil }
        let scanned = VkKeyScanW(WCHAR(unit))
        return scanned == -1 ? nil : Int32(scanned & 0xFF)
      }
      return switch key {
      case .space: VK_SPACE
      case .return: VK_RETURN
      case .escape: VK_ESCAPE
      case .tab: VK_TAB
      case .backspace: VK_BACK
      case .delete: VK_DELETE
      case .left: VK_LEFT
      case .right: VK_RIGHT
      case .up: VK_UP
      case .down: VK_DOWN
      case .home: VK_HOME
      case .end: VK_END
      case .pageUp: VK_PRIOR
      case .pageDown: VK_NEXT
      case .function(let number): (1...24).contains(number) ? VK_F1 + Int32(number - 1) : nil
      case .character: nil
      }
    }

    /// What a key types with nothing held but shift — so that a shortcut held with control is still
    /// known by its letter — or nil for a key that types nothing.
    static func character(virtualKey: UINT, scanCode: UINT, shift: Bool) -> Character? {
      var state = [UInt8](repeating: 0, count: 256)
      if shift { state[Int(VK_SHIFT)] = 0x80 }
      var typed = [WCHAR](repeating: 0, count: 8)
      // 0x4: leave the keyboard's dead-key state as it was.
      let count = ToUnicode(virtualKey, scanCode, &state, &typed, Int32(typed.count), 0x4)
      guard count == 1, typed[0] >= 0x20, typed[0] != 0x7F else { return nil }
      return Character(Unicode.Scalar(UInt16(typed[0])) ?? " ")
    }

    /// The modifiers held now, as Windows keeps them for the message being handled.
    static func modifiers() -> Modifiers {
      var held: Modifiers = []
      if GetKeyState(VK_SHIFT) < 0 { held.insert(.shift) }
      if GetKeyState(VK_CONTROL) < 0 { held.insert(.control) }
      if GetKeyState(VK_MENU) < 0 { held.insert(.option) }
      if GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0 { held.insert(.command) }
      return held
    }

    /// A key message's event, or nil for a key that is neither named nor types anything.
    static func key(virtualKey: WPARAM, lParam: LPARAM, isDown: Bool, modifiers: Modifiers) -> KeyEvent? {
      let code = Int32(truncatingIfNeeded: virtualKey)
      let key: Key
      if let named = namedKey(code) {
        key = named
      } else {
        let scanCode = UINT((lParam >> 16) & 0xFF)
        guard
          let typed = character(
            virtualKey: UINT(truncatingIfNeeded: virtualKey), scanCode: scanCode,
            shift: modifiers.contains(.shift))
        else { return nil }
        key = .character(typed)
      }
      // Bit 30: the key was already down, which on a key down means it is repeating.
      let repeating = isDown && (lParam >> 30) & 1 == 1
      return KeyEvent(key: key, modifiers: modifiers, isDown: isDown, isRepeat: repeating)
    }

    /// A mouse message's position, in pixels from the client area's top left: the low and high
    /// words of `lParam`, each signed, since a captured mouse can be left of or above the window.
    static func position(_ lParam: LPARAM) -> SIMD2<Float> {
      SIMD2(Float(Int16(truncatingIfNeeded: lParam)), Float(Int16(truncatingIfNeeded: lParam >> 16)))
    }

    /// Wheel units to points. A notch is 120 units; a notch is taken as three lines of sixteen
    /// points, which is what Windows' own lists scroll by.
    static let pointsPerNotch: Float = 48
  }
#endif
