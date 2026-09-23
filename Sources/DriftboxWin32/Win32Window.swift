#if os(Windows)
  import WinSDK

  /// A top-level window, and the messages that arrive for it: the start of Driftbox's Windows
  /// shell. What is drawn in it is the GPU layer's affair; this keeps the window, its size in
  /// pixels, and whether it is still open.
  ///
  /// The process is made aware of each monitor's DPI before the first window, so a window's size
  /// is in real pixels and the GPU draws at the display's own resolution rather than being scaled
  /// up blurred by Windows.
  public final class Win32Window {
    public private(set) var handle: HWND!
    /// The client area, in pixels.
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var isOpen = true
    /// The client area's new size, in pixels, after the window is resized.
    public var onResize: ((Int, Int) -> Void)?

    /// A window of `width` by `height` pixels of client area, titled `title`. `visible` false
    /// makes one that is never shown, for a test to draw into.
    public init(title: String, width: Int, height: Int, visible: Bool = true) throws {
      Self.prepare()
      var frame = RECT(left: 0, top: 0, right: LONG(width), bottom: LONG(height))
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
      var client = RECT()
      GetClientRect(made, &client)
      self.width = Int(client.right - client.left)
      self.height = Int(client.bottom - client.top)
    }

    deinit {
      if isOpen, let handle { DestroyWindow(handle) }
    }

    /// Everything that has arrived, handled, without waiting for more. False once the window has
    /// been closed, which is when a loop that calls this every frame should stop.
    @discardableResult
    public func pump() -> Bool {
      var message = MSG()
      while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
        TranslateMessage(&message)
        DispatchMessageW(&message)
      }
      return isOpen
    }

    public func close() {
      guard isOpen, let handle else { return }
      DestroyWindow(handle)
    }

    // MARK: - Messages

    private func receive(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
      switch Int32(message) {
      case WM_SIZE:
        let width = Int(lParam & 0xFFFF)
        let height = Int((lParam >> 16) & 0xFFFF)
        guard width > 0, height > 0, width != self.width || height != self.height else { return 0 }
        self.width = width
        self.height = height
        onResize?(width, height)
        return 0
      case WM_DESTROY:
        isOpen = false
        return 0
      default:
        return nil
      }
    }

    private static let className = "DriftboxWindow"
    private nonisolated(unsafe) static var prepared = false

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

    /// The window procedure: the window found again from the pointer it was made with, kept in
    /// its user data from the first message on.
    private static let procedure: WNDPROC = { window, message, wParam, lParam in
      guard let window else { return 0 }
      if message == UINT(WM_NCCREATE) {
        let create = UnsafePointer<CREATESTRUCTW>(bitPattern: UInt(lParam))
        SetWindowLongPtrW(window, GWLP_USERDATA, LONG_PTR(Int(bitPattern: create?.pointee.lpCreateParams)))
      }
      let stored = GetWindowLongPtrW(window, GWLP_USERDATA)
      if let pointer = UnsafeRawPointer(bitPattern: Int(stored)) {
        let owner = Unmanaged<Win32Window>.fromOpaque(pointer).takeUnretainedValue()
        if let handled = owner.receive(message, wParam, lParam) { return handled }
      }
      return DefWindowProcW(window, message, wParam, lParam)
    }
  }

  public struct Win32Error: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
  }
#endif
