#if os(Windows)
  import DriftboxShell
  import WinSDK

  /// The visuals, in a window of their own: `ShellVisualsWindow` on Windows. Full screen is as
  /// Windows' own players have it — the window's frame taken away and the window laid over the
  /// whole monitor, taskbar and all — and Escape, F11 or a double-click leave it. A pointer left
  /// still over the picture is hidden after two seconds and comes back as it moves, and the display
  /// is kept from sleeping while the window is open: a projector going dark in the middle of a set
  /// is the thing least wanted.
  @MainActor
  public final class Win32VisualsWindow: ShellVisualsWindow {
    public private(set) var handle: HWND!
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var scale: Float = 1
    public private(set) var isFullScreen = false
    public private(set) var isOpen = true
    public var onEvent: ((VisualsEvent) -> Void)?
    /// Where the window was before it went full screen, to go back to.
    private var placement = WINDOWPLACEMENT()
    private var pointerHidden = false
    private static let hideTimer: UINT_PTR = 1
    private static let windowed = DWORD(WS_OVERLAPPEDWINDOW)
    private static let className = "DriftboxVisuals"

    /// A window 960 by 540 points, not shown until `show`. `visible` false keeps it from ever being
    /// shown, for a test.
    public init(visible: Bool = true) throws {
      self.visible = visible
      Self.prepare()
      let dpi = GetDpiForSystem()
      var frame = RECT(left: 0, top: 0, right: LONG(960 * dpi / 96), bottom: LONG(540 * dpi / 96))
      AdjustWindowRectExForDpi(&frame, Self.windowed, false, 0, dpi)
      let context = Unmanaged.passUnretained(self).toOpaque()
      let made = "Visuals".withCString(encodedAs: UTF16.self) { title in
        Self.className.withCString(encodedAs: UTF16.self) { className in
          CreateWindowExW(
            0, className, title, Self.windowed, CW_USEDEFAULT, CW_USEDEFAULT, frame.right - frame.left,
            frame.bottom - frame.top, nil, nil, GetModuleHandleW(nil), context)
        }
      }
      guard let made else { throw Win32Error("the visuals window could not be made (\(GetLastError()))") }
      handle = made
      scale = Float(GetDpiForWindow(made)) / 96
      var client = RECT()
      GetClientRect(made, &client)
      width = Int(client.right - client.left)
      height = Int(client.bottom - client.top)
      placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
      // The display kept awake, for as long as the window is open.
      _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED))
    }
    private let visible: Bool

    isolated deinit { close() }

    public var display: String? { Win32Displays.display(of: handle)?.name }

    public func show(on display: String?, fullScreen: Bool) {
      guard isOpen else { return }
      let target = display.flatMap { name in Win32Displays.all().first { $0.name == name } }
      if let target {
        if isFullScreen {
          cover(target.bounds)
        } else {
          // The window's size kept, centred in the part of the display not under the taskbar.
          var frame = RECT()
          GetWindowRect(handle, &frame)
          let across = frame.right - frame.left
          let down = frame.bottom - frame.top
          let area = target.work
          SetWindowPos(
            handle, nil, area.left + (area.right - area.left - across) / 2,
            area.top + (area.bottom - area.top - down) / 2, 0, 0,
            UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        }
      }
      if visible {
        ShowWindow(handle, SW_SHOW)
        SetForegroundWindow(handle)
      }
      setFullScreen(fullScreen)
    }

    /// Into full screen on the display it is on, or out of it to where it was before.
    public func setFullScreen(_ on: Bool) {
      guard isOpen, on != isFullScreen else { return }
      if on {
        GetWindowPlacement(handle, &placement)
        isFullScreen = true
        SetWindowLongPtrW(handle, GWL_STYLE, LONG_PTR(WS_POPUP) | (visible ? LONG_PTR(WS_VISIBLE) : 0))
        cover(Win32Displays.display(of: handle)?.bounds ?? RECT(left: 0, top: 0, right: 960, bottom: 540))
      } else {
        isFullScreen = false
        SetWindowLongPtrW(handle, GWL_STYLE, LONG_PTR(Self.windowed) | (visible ? LONG_PTR(WS_VISIBLE) : 0))
        SetWindowPlacement(handle, &placement)
        SetWindowPos(
          handle, nil, 0, 0, 0, 0,
          UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED))
      }
      onEvent?(.moved)
    }

    /// The window over the whole of `bounds`, above the others: HWND_TOP, which is nil.
    private func cover(_ bounds: RECT) {
      SetWindowPos(
        handle, nil, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top,
        UINT(SWP_FRAMECHANGED | SWP_NOACTIVATE))
    }

    public func close() {
      guard isOpen else { return }
      isOpen = false
      _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS))
      if let handle { DestroyWindow(handle) }
    }

    // MARK: - What it hears

    private func receive(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
      switch message {
      case UINT(WM_SIZE):
        let width = Int(lParam & 0xFFFF)
        let height = Int((lParam >> 16) & 0xFFFF)
        guard width > 0, height > 0, width != self.width || height != self.height else { return 0 }
        self.width = width
        self.height = height
        onEvent?(.resized(width: width, height: height, scale: scale))
        return 0
      case UINT(WM_DPICHANGED):
        scale = Float(wParam & 0xFFFF) / 96
        if !isFullScreen, let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
          SetWindowPos(
            handle, nil, suggested.left, suggested.top, suggested.right - suggested.left,
            suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        onEvent?(.resized(width: width, height: height, scale: scale))
        return 0
      case UINT(WM_EXITSIZEMOVE):
        onEvent?(.moved)
        return 0
      case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN):
        let key = Int32(truncatingIfNeeded: wParam)
        if key == VK_ESCAPE, isFullScreen {
          setFullScreen(false)
          return 0
        }
        if key == VK_F11 {
          setFullScreen(!isFullScreen)
          return 0
        }
        if let event = Win32Input.key(
          virtualKey: wParam, lParam: lParam, isDown: true, modifiers: Win32Input.modifiers())
        {
          onEvent?(.key(event))
        }
        return message == UINT(WM_KEYDOWN) ? 0 : nil
      case UINT(WM_LBUTTONDBLCLK):
        setFullScreen(!isFullScreen)
        return 0
      case UINT(WM_MOUSEMOVE):
        // Back as it moves; hidden again once it has been still for two seconds.
        if pointerHidden {
          pointerHidden = false
          SetCursor(LoadCursorW(nil, UnsafePointer(bitPattern: 32512)))
        }
        SetTimer(handle, Self.hideTimer, 2000, nil)
        return 0
      case UINT(WM_TIMER) where wParam == Self.hideTimer:
        KillTimer(handle, Self.hideTimer)
        var point = POINT()
        GetCursorPos(&point)
        if WindowFromPoint(point) == handle {
          pointerHidden = true
          SetCursor(nil)
        }
        return 0
      case UINT(WM_SETCURSOR) where pointerHidden && (lParam & 0xFFFF) == HTCLIENT:
        SetCursor(nil)
        return 1
      case UINT(WM_CLOSE):
        // A person closing it: told first, then gone.
        onEvent?(.closed)
        close()
        return 0
      case UINT(WM_DESTROY):
        isOpen = false
        return 0
      default:
        return nil
      }
    }

    private static var prepared = false

    private static func prepare() {
      guard !prepared else { return }
      prepared = true
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        // Double-clicks, for full screen.
        windowClass.style = UINT(CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS)
        windowClass.lpfnWndProc = procedure
        windowClass.hInstance = GetModuleHandleW(nil)
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))  // IDC_ARROW
        windowClass.hIcon = LoadIconW(windowClass.hInstance, UnsafePointer(bitPattern: 1))
        windowClass.hbrBackground = GetStockObject(BLACK_BRUSH)?.assumingMemoryBound(to: HBRUSH__.self)
        windowClass.lpszClassName = name
        RegisterClassExW(&windowClass)
      }
    }

    /// As the main window's: the window found again from the pointer it was made with.
    private static let procedure: WNDPROC = { window, message, wParam, lParam in
      guard let window else { return 0 }
      if message == UINT(WM_NCCREATE) {
        let create = UnsafePointer<CREATESTRUCTW>(bitPattern: UInt(lParam))
        SetWindowLongPtrW(window, GWLP_USERDATA, LONG_PTR(Int(bitPattern: create?.pointee.lpCreateParams)))
      }
      let stored = GetWindowLongPtrW(window, GWLP_USERDATA)
      if let pointer = UnsafeRawPointer(bitPattern: Int(stored)) {
        let handled = MainActor.assumeIsolated {
          Unmanaged<Win32VisualsWindow>.fromOpaque(pointer).takeUnretainedValue().receive(
            message, wParam, lParam)
        }
        if let handled { return handled }
      }
      return DefWindowProcW(window, message, wParam, lParam)
    }
  }
#endif
