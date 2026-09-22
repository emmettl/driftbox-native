#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(Metal)
  import AppKit
  import DriftboxEngine
  import DriftboxScenes
  import MetalKit
  import Observation
  import SwiftUI

  /// The visuals, drawn once a frame and shown wherever they are wanted.
  ///
  /// One renderer and one scene, whatever is watching. That is what makes a second view safe
  /// rather than merely possible: the engine's events are taken by whoever draws, so two
  /// renderers would each see half the hits, and the analyser smooths every time it is asked,
  /// so two would make the bands fall twice as fast. It is also what makes the pane an honest
  /// preview — while a visuals window is open that window draws the frame at its own shape, and
  /// the pane shows the same frame letterboxed, rather than a second scene of its own that
  /// happens to look similar.
  @MainActor
  @Observable
  public final class Stage {
    @ObservationIgnored let player: Player
    @ObservationIgnored let renderer: SceneRenderer?
    /// The window the visuals go out to.
    @ObservationIgnored public private(set) lazy var output = VisualsWindow(stage: self)
    /// Whether that window is open. While it is, it draws and the pane previews.
    internal(set) public var outputOpen = false
    /// The displays attached, by name, for the menu that sends the visuals to one. Kept here
    /// rather than read from `NSScreen` in the menu, because a menu only redraws when something
    /// it observes changes — and plugging a projector in is exactly when it has to.
    public private(set) var screens: [String] = NSScreen.screens.map(\.localizedName)

    /// Two frames in turn, so a view can still be showing one while the next is drawn into the
    /// other rather than waiting for it.
    @ObservationIgnored private var ring: [MTLTexture] = []
    @ObservationIgnored private var next = 0
    /// The last frame drawn, which every view shows.
    @ObservationIgnored private(set) var latest: MTLTexture?

    public init(player: Player) {
      self.player = player
      renderer = try? SceneRenderer(now: CACurrentMediaTime())
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.screens = NSScreen.screens.map(\.localizedName) }
      }
    }

    /// Draw one frame, `size` pixels at `pixelRatio` pixels to the point.
    func render(size: SIMD2<Int>, pixelRatio: Float) {
      guard let renderer, size.x > 0, size.y > 0 else { return }
      try? renderer.show(player.song?.visual)
      if ring.first.map({ $0.width != size.x || $0.height != size.y }) ?? true {
        ring = (0..<2).compactMap { _ in Self.frame(size, on: renderer.device) }
        next = 0
      }
      guard !ring.isEmpty else { return }
      let target = ring[next]
      next = (next + 1) % ring.count

      let peaks = player.peaks
      let position = player.position
      let analyser = player.analyse()
      let input = SceneInput(
        time: CACurrentMediaTime(), peakLeft: peaks.left, peakRight: peaks.right,
        events: player.takeEvents(), touch: player.padTouch, bar: position?.bar ?? 0,
        step: position?.step ?? 0, running: player.isPlaying, bpm: player.tempo,
        scoreBeat: player.scoreBeat(), levels: analyser?.levels() ?? (0, 0, 0),
        wideLevels: analyser?.wideLevels() ?? (0, 0), bands: analyser?.bands(16) ?? [],
        pixelRatio: pixelRatio)
      renderer.draw(input, into: target)
      latest = target
    }

    private static func frame(_ size: SIMD2<Int>, on device: MTLDevice) -> MTLTexture? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Remembered between launches

    /// Put the visuals window back if it was open when the app last quit, on the display it
    /// was on and full screen if it was. A performer's projector setup is the thing least worth
    /// having to rebuild by hand every time.
    public func restore() {
      let defaults = UserDefaults.standard
      guard defaults.bool(forKey: Defaults.outputOpen) else { return }
      output.show(
        on: defaults.string(forKey: Defaults.outputScreen),
        fullScreen: defaults.bool(forKey: Defaults.outputFullScreen))
    }
  }

  /// A view onto the stage: the pane in the main window, or the whole of the visuals window.
  struct StageView: NSViewRepresentable {
    let stage: Stage
    let role: StageMTKView.Role

    func makeNSView(context: Context) -> StageMTKView { StageMTKView(stage: stage, role: role) }
    func updateNSView(_ view: StageMTKView, context: Context) {}
  }

  /// The Metal view both of those are. Whichever is the output draws the frame — the visuals
  /// window when one is open, the pane when not — and both show it.
  final class StageMTKView: MTKView, MTKViewDelegate {
    enum Role { case preview, output }
    let stage: Stage
    let role: Role
    private var hideCursor: Timer?

    init(stage: Stage, role: Role) {
      self.stage = stage
      self.role = role
      super.init(frame: .zero, device: stage.renderer?.device)
      colorPixelFormat = .bgra8Unorm
      clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      preferredFramesPerSecond = 60
      delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("a stage view is made in code") }

    /// The output runs at whatever its display can manage — a projector at sixty, a laptop's
    /// own panel at a hundred and twenty. The preview never needs to be smoother than sixty.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      preferredFramesPerSecond = role == .output ? (window?.screen?.maximumFramesPerSecond ?? 60) : 60
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      if role == .output || !stage.outputOpen {
        stage.render(
          size: SIMD2(Int(drawableSize.width), Int(drawableSize.height)),
          pixelRatio: Float(window?.backingScaleFactor ?? 1))
      }
      guard let frame = stage.latest, let drawable = currentDrawable else { return }
      stage.renderer?.present(frame, into: drawable.texture, drawable: drawable)
    }

    // MARK: - The output, as something a performer stands in front of

    override var acceptsFirstResponder: Bool { role == .output }

    /// Escape leaves full screen, as it does in every other app that shows something full
    /// screen, and space still plays and stops — the visuals window is often the one in front,
    /// and the main window's keys do not reach it.
    override func keyDown(with event: NSEvent) {
      guard role == .output else { return super.keyDown(with: event) }
      switch event.keyCode {
      case 53 where window?.styleMask.contains(.fullScreen) == true: window?.toggleFullScreen(nil)
      case 49: stage.player.toggle()
      default: super.keyDown(with: event)
      }
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      guard role == .output else { return }
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    /// A pointer parked over the picture is hidden after a moment, and comes back the moment it
    /// moves. Only while it is still over this view: hiding it over some other window would be
    /// hiding somebody else's pointer.
    override func mouseMoved(with event: NSEvent) {
      guard role == .output else { return }
      hideCursor?.invalidate()
      hideCursor = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let window = self.window else { return }
          let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
          if self.bounds.contains(point) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
      }
    }
  }

  /// The window the visuals go out to: movable to another display, full screen on it, and
  /// remembered. A plain AppKit window rather than a SwiftUI scene, because which display it is
  /// on and when it goes full screen are the whole point of it, and those are AppKit's to give.
  @MainActor
  public final class VisualsWindow: NSObject, NSWindowDelegate {
    unowned let stage: Stage
    private var window: NSWindow?
    /// Held while the window is open, so the display does not go to sleep in the middle of a set.
    private var awake: NSObjectProtocol?
    /// A move to another display asked for while full screen on this one, carried out once
    /// full screen has been left — a window can only go full screen on the display it is on.
    private var pending: (screen: String?, fullScreen: Bool)?

    init(stage: Stage) {
      self.stage = stage
    }

    public var isOpen: Bool { window != nil }

    public func toggle() {
      if isOpen { close() } else { show() }
    }

    /// Open the window — on the named display if there is one by that name, full screen there
    /// if asked. With no display named it opens where it was last.
    public func show(on screenName: String? = nil, fullScreen: Bool = false) {
      let window = self.window ?? make()
      let screen = screenName.flatMap { name in NSScreen.screens.first { $0.localizedName == name } }
      if let screen, window.screen != screen, window.styleMask.contains(.fullScreen) {
        pending = (screenName, fullScreen)
        window.toggleFullScreen(nil)
        return
      }
      if let screen, window.screen != screen {
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrame(
          NSRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
            height: size.height),
          display: false)
      }
      window.makeKeyAndOrderFront(nil)
      if fullScreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      remember()
    }

    public func close() {
      window?.close()
    }

    private func make() -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "Visuals"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.backgroundColor = .black
      window.collectionBehavior = [.fullScreenPrimary, .managed]
      window.isReleasedWhenClosed = false
      window.acceptsMouseMovedEvents = true
      window.contentView = StageMTKView(stage: stage, role: .output)
      window.delegate = self
      // Where it sat and how big, between launches, for the times it is opened without a
      // display being named. The first time there is nothing to put back, and a window's own
      // origin is the corner of the screen, which is nowhere anybody looks for a new window.
      if !window.setFrameUsingName("Visuals") { window.center() }
      window.setFrameAutosaveName("Visuals")
      self.window = window
      stage.outputOpen = true
      awake = ProcessInfo.processInfo.beginActivity(
        options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Showing the visuals")
      return window
    }

    private func remember() {
      guard let window else { return }
      let defaults = UserDefaults.standard
      defaults.set(true, forKey: Defaults.outputOpen)
      defaults.set(window.screen?.localizedName, forKey: Defaults.outputScreen)
      defaults.set(window.styleMask.contains(.fullScreen), forKey: Defaults.outputFullScreen)
    }

    public func windowWillClose(_ notification: Notification) {
      if let awake { ProcessInfo.processInfo.endActivity(awake) }
      awake = nil
      window?.contentView = nil
      window = nil
      stage.outputOpen = false
      UserDefaults.standard.set(false, forKey: Defaults.outputOpen)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
      remember()
      window?.makeFirstResponder(window?.contentView)
      NSCursor.setHiddenUntilMouseMoves(true)
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
      if let pending {
        self.pending = nil
        show(on: pending.screen, fullScreen: pending.fullScreen)
      } else {
        remember()
      }
    }

    public func windowDidChangeScreen(_ notification: Notification) {
      remember()
    }
  }
#endif
