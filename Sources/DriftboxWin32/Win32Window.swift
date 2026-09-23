#if os(Windows)
  import DriftboxShell
  import Foundation
  import Synchronization
  import WinSDK

  /// A top-level window and the messages that arrive for it: `ShellWindow` on Windows.
  ///
  /// The process is made aware of each monitor's DPI before the first window, so a window's size
  /// is in real pixels and the GPU draws at the display's own resolution rather than being scaled
  /// up blurred by Windows; `scale` says how many of them make a point.
  ///
  /// While a window is dragged or resized Windows runs a loop of its own and `run`'s stops. So the
  /// window starts a timer as a move or resize begins, and draws a frame on every tick of it and on
  /// every change of size until it ends: the picture follows the edge rather than freezing.
  @MainActor
  public final class Win32Window: ShellWindow {
    public private(set) var handle: HWND!
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var scale: Float = 1
    public private(set) var isOpen = true
    /// Whether Windows is moving or resizing the window, and running its own loop to do it.
    public private(set) var isResizing = false
    public var onEvent: ((ShellEvent) -> Void)?
    public var isEnabled: ((String) -> Bool)?

    public var title: String {
      didSet { title.withCString(encodedAs: UTF16.self) { _ = SetWindowTextW(handle, $0) } }
    }

    public var menuBar: MenuBar? {
      didSet {
        guard menuBar != oldValue else { return }
        let built = menuBar.map(Win32Menus.init)
        SetMenu(handle, built?.menu)
        menus = built
        DrawMenuBar(handle)
      }
    }
    private var menus: Win32Menus?

    /// The frame `run` was given, while it runs, for the modal loop's timer to call.
    private var frame: (() throws -> Void)?
    private var drawing = false
    private var failure: (any Error)?
    /// The mouse button held, if one is, so that its moves and its release go to the same pointer.
    private var held: Int?
    private static let resizeTimer: UINT_PTR = 1
    private let mailbox = Mailbox()

    /// A window of `width` by `height` points of drawing area, titled `title`. `visible` false makes
    /// one that is never shown, for a test to draw into.
    public init(title: String, width: Int, height: Int, visible: Bool = true) throws {
      self.title = title
      Self.prepare()
      let scale = Float(GetDpiForSystem()) / 96
      var frame = RECT(
        left: 0, top: 0, right: LONG(Float(width) * scale), bottom: LONG(Float(height) * scale))
      AdjustWindowRectExForDpi(&frame, DWORD(WS_OVERLAPPEDWINDOW), false, 0, GetDpiForSystem())
      let context = Unmanaged.passUnretained(self).toOpaque()
      let made = title.withCString(encodedAs: UTF16.self) { title in
        Self.className.withCString(encodedAs: UTF16.self) { className in
          CreateWindowExW(
            0, className, title, DWORD(WS_OVERLAPPEDWINDOW) | (visible ? DWORD(WS_VISIBLE) : 0),
            CW_USEDEFAULT, CW_USEDEFAULT, frame.right - frame.left, frame.bottom - frame.top, nil, nil,
            GetModuleHandleW(nil), context)
        }
      }
      guard let made else { throw Win32Error("the window could not be made (\(GetLastError()))") }
      handle = made
      mailbox.open(made)
      self.scale = Float(GetDpiForWindow(made)) / 96
      var client = RECT()
      GetClientRect(made, &client)
      self.width = Int(client.right - client.left)
      self.height = Int(client.bottom - client.top)
    }

    isolated deinit {
      if isOpen, let handle { DestroyWindow(handle) }
    }

    public func run(frame: () throws -> Void) throws {
      try withoutActuallyEscaping(frame) { frame in
        self.frame = frame
        defer { self.frame = nil }
        while pump() {
          try draw(frame)
          if let failure {
            self.failure = nil
            throw failure
          }
        }
      }
    }

    /// Everything that has arrived, handled, without waiting for more — shortcuts first, as
    /// Windows' own applications take them. False once the window has been closed.
    @discardableResult
    public func pump() -> Bool {
      var message = MSG()
      while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
        if let accelerators = menus?.accelerators, TranslateAcceleratorW(handle, accelerators, &message) != 0
        {
          continue
        }
        TranslateMessage(&message)
        DispatchMessageW(&message)
      }
      return isOpen
    }

    public func close() {
      guard isOpen, let handle else { return }
      DestroyWindow(handle)
    }

    public nonisolated func post(_ work: @escaping @Sendable () -> Void) {
      mailbox.post(work)
    }

    /// Work for the window's thread, from any thread: kept under a lock, and the window woken with a
    /// message of its own to take it. A window that has gone takes nothing, and nothing is kept.
    final class Mailbox: Sendable {
      static let message = UINT(WM_APP) + 1
      private let state = Mutex<(window: UInt, queue: [@Sendable () -> Void])>((0, []))

      func open(_ window: HWND) { state.withLock { $0.window = UInt(bitPattern: window) } }
      func shut() { state.withLock { $0 = (0, []) } }

      func post(_ work: @escaping @Sendable () -> Void) {
        let window = state.withLock { state -> UInt in
          if state.window != 0 { state.queue.append(work) }
          return state.window
        }
        if let handle = HWND(bitPattern: window) { PostMessageW(handle, Self.message, 0, 0) }
      }

      func take() -> [@Sendable () -> Void] {
        state.withLock { state in
          defer { state.queue = [] }
          return state.queue
        }
      }
    }

    public func chooseFile(ofTypes types: [FileType]) -> URL? {
      Win32Files.open(owner: handle, types: types)
    }

    public func chooseSaveLocation(for type: FileType, name: String) -> URL? {
      Win32Files.save(owner: handle, type: type, name: name)
    }

    /// A frame, unless one is already being drawn: the modal loop's timer can fire while a frame
    /// is presenting, and a frame drawn inside another would draw into a target still in use.
    private func draw(_ frame: () throws -> Void) throws {
      guard !drawing else { return }
      drawing = true
      defer { drawing = false }
      try frame()
    }

    /// A frame from inside a message, where there is nowhere to throw to: an error waits for `run`.
    private func drawFromMessage() {
      guard let frame else { return }
      do { try draw(frame) } catch { failure = error }
    }

    private func point(_ pixels: SIMD2<Float>) -> SIMD2<Float> { pixels / scale }

    // MARK: - Messages

    // Messages the WinSDK module does not name.
    private static let pointerDown: UINT = 0x0246
    private static let pointerUpdate: UINT = 0x0245
    private static let pointerUp: UINT = 0x0247
    private static let pointerCaptureChanged: UINT = 0x024C
    private static let dpiChanged: UINT = 0x02E0

    private func receive(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
      switch message {
      case UINT(WM_SIZE):
        let width = Int(lParam & 0xFFFF)
        let height = Int((lParam >> 16) & 0xFFFF)
        guard width > 0, height > 0, width != self.width || height != self.height else { return 0 }
        self.width = width
        self.height = height
        onEvent?(.resized(width: width, height: height, scale: scale))
        if isResizing { drawFromMessage() }
        return 0
      case Self.dpiChanged:
        scale = Float(wParam & 0xFFFF) / 96
        if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
          SetWindowPos(
            handle, nil, suggested.left, suggested.top, suggested.right - suggested.left,
            suggested.bottom - suggested.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        onEvent?(.resized(width: width, height: height, scale: scale))
        return 0
      case UINT(WM_ENTERSIZEMOVE):
        isResizing = true
        SetTimer(handle, Self.resizeTimer, 16, nil)
        return 0
      case UINT(WM_EXITSIZEMOVE):
        isResizing = false
        KillTimer(handle, Self.resizeTimer)
        return 0
      case UINT(WM_TIMER) where wParam == Self.resizeTimer:
        drawFromMessage()
        return 0

      case UINT(WM_KEYDOWN), UINT(WM_KEYUP), UINT(WM_SYSKEYDOWN), UINT(WM_SYSKEYUP):
        let isDown = message == UINT(WM_KEYDOWN) || message == UINT(WM_SYSKEYDOWN)
        if let event = Win32Input.key(
          virtualKey: wParam, lParam: lParam, isDown: isDown, modifiers: Win32Input.modifiers())
        {
          onEvent?(.key(event))
        }
        // Alt's keys are the system's too — Alt and a letter opens a menu, Alt+F4 closes.
        let system = message == UINT(WM_SYSKEYDOWN) || message == UINT(WM_SYSKEYUP)
        return system ? nil : 0

      case UINT(WM_LBUTTONDOWN), UINT(WM_RBUTTONDOWN):
        let button = message == UINT(WM_LBUTTONDOWN) ? 0 : 1
        held = button
        SetCapture(handle)
        mouse(.began, lParam, button: button)
        return 0
      case UINT(WM_MOUSEMOVE):
        mouse(.moved, lParam, button: held ?? 0)
        return 0
      case UINT(WM_LBUTTONUP), UINT(WM_RBUTTONUP):
        let button = message == UINT(WM_LBUTTONUP) ? 0 : 1
        guard held == button else { return 0 }
        held = nil
        mouse(.ended, lParam, button: button)
        ReleaseCapture()
        return 0
      case UINT(WM_CAPTURECHANGED):
        if let button = held {
          held = nil
          onEvent?(
            .pointer(
              PointerEvent(
                phase: .cancelled, location: .zero, button: button, modifiers: Win32Input.modifiers())))
        }
        return 0

      case Self.pointerDown, Self.pointerUpdate, Self.pointerUp, Self.pointerCaptureChanged:
        return pointer(message, wParam, lParam)

      case UINT(WM_MOUSEWHEEL), UINT(WM_MOUSEHWHEEL):
        var screen = POINT(
          x: LONG(Int16(truncatingIfNeeded: lParam)), y: LONG(Int16(truncatingIfNeeded: lParam >> 16)))
        ScreenToClient(handle, &screen)
        let notches = Float(Int16(truncatingIfNeeded: wParam >> 16)) / 120 * Win32Input.pointsPerNotch
        // A wheel rolled toward you, or tilted right, moves the content the way a finger would.
        let delta = message == UINT(WM_MOUSEWHEEL) ? SIMD2(0, -notches) : SIMD2(-notches, 0)
        onEvent?(.scroll(ScrollEvent(location: point(SIMD2(Float(screen.x), Float(screen.y))), delta: delta)))
        return 0

      case UINT(WM_COMMAND):
        let id = Int(wParam & 0xFFFF)
        if let command = menus?.command(id), isEnabled?(command.id) ?? true {
          onEvent?(.command(command.id))
        }
        return 0
      case UINT(WM_INITMENUPOPUP):
        if let menus, let popup = HMENU(bitPattern: UInt(wParam)) {
          menus.refresh(popup) { self.isEnabled?($0) ?? true }
        }
        return 0

      case Mailbox.message:
        for work in mailbox.take() { work() }
        return 0

      case UINT(WM_DESTROY):
        isOpen = false
        mailbox.shut()
        KillTimer(handle, Self.resizeTimer)
        return 0
      default:
        return nil
      }
    }

    private func mouse(_ phase: PointerEvent.Phase, _ lParam: LPARAM, button: Int) {
      onEvent?(
        .pointer(
          PointerEvent(
            phase: phase, id: 0, kind: .mouse, location: point(Win32Input.position(lParam)), button: button,
            modifiers: Win32Input.modifiers())))
    }

    /// Touch and pen, as pointers of their own. The mouse is left to its own messages, which
    /// Windows sends for it as long as its pointer messages go unanswered here.
    private func pointer(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
      let id = UINT32(wParam & 0xFFFF)
      var type = POINTER_INPUT_TYPE(0)
      guard GetPointerType(id, &type), type == UInt32(PT_TOUCH.rawValue) || type == UInt32(PT_PEN.rawValue)
      else {
        return nil
      }
      var screen = POINT(
        x: LONG(Int16(truncatingIfNeeded: lParam)), y: LONG(Int16(truncatingIfNeeded: lParam >> 16)))
      ScreenToClient(handle, &screen)
      let phase: PointerEvent.Phase =
        switch message {
        case Self.pointerDown: .began
        case Self.pointerUp: .ended
        case Self.pointerCaptureChanged: .cancelled
        default: .moved
        }
      onEvent?(
        .pointer(
          PointerEvent(
            phase: phase, id: Int(id) + 1, kind: type == UInt32(PT_PEN.rawValue) ? .pen : .touch,
            location: point(SIMD2(Float(screen.x), Float(screen.y))), modifiers: Win32Input.modifiers())))
      return 0
    }

    private static let className = "DriftboxWindow"
    private static var prepared = false

    /// The window class, once, and the process made aware of each monitor's DPI.
    private static func prepare() {
      guard !prepared else { return }
      prepared = true
      // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, which the headers spell as a cast of -4.
      _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
      className.withCString(encodedAs: UTF16.self) { name in
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.style = UINT(CS_HREDRAW | CS_VREDRAW)
        windowClass.lpfnWndProc = procedure
        windowClass.hInstance = GetModuleHandleW(nil)
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))  // IDC_ARROW
        windowClass.lpszClassName = name
        RegisterClassExW(&windowClass)
      }
    }

    /// The window procedure: the window found again from the pointer it was made with, kept in its
    /// user data from the first message on. Windows calls it on the thread that made the window,
    /// which is the main one.
    private static let procedure: WNDPROC = { window, message, wParam, lParam in
      guard let window else { return 0 }
      if message == UINT(WM_NCCREATE) {
        let create = UnsafePointer<CREATESTRUCTW>(bitPattern: UInt(lParam))
        SetWindowLongPtrW(window, GWLP_USERDATA, LONG_PTR(Int(bitPattern: create?.pointee.lpCreateParams)))
      }
      let stored = GetWindowLongPtrW(window, GWLP_USERDATA)
      if let pointer = UnsafeRawPointer(bitPattern: Int(stored)) {
        let handled = MainActor.assumeIsolated {
          Unmanaged<Win32Window>.fromOpaque(pointer).takeUnretainedValue().receive(message, wParam, lParam)
        }
        if let handled { return handled }
      }
      return DefWindowProcW(window, message, wParam, lParam)
    }
  }

  public struct Win32Error: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
  }
#endif
