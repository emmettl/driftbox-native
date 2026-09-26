import DriftboxGPU
import DriftboxHost
import DriftboxShell
import Foundation

/// The visuals in a window of their own, for a projector or a second screen, as the Mac's are: sent
/// to a display by name and full screen there from the View menu, and put back where they were at
/// the next launch.
///
/// One scene, whatever is watching. While the window is open it draws the frame at its own shape,
/// and the main window's backdrop shows that same frame, cropped to fill, rather than a second
/// scene of its own: the engine's events are taken by whoever draws, so two scenes would each see
/// half the hits.
extension Desktop {
  /// Where the window is kept between launches, under the Mac's own keys.
  enum VisualsMemory {
    static let open = "visuals.window.open"
    static let display = "visuals.window.screen"
    static let fullScreen = "visuals.window.fullScreen"
  }

  public var visualsOpen: Bool { visuals != nil }

  /// Open the window, or bring it forward: on the display named, if there is one by that name, and
  /// full screen there if asked. Nothing where the platform has no second window.
  public func showVisuals(on display: String? = nil, fullScreen: Bool = false) {
    if visuals == nil {
      guard let made = window.makeVisualsWindow(), let makeVisualsSurface,
        let surface = try? makeVisualsSurface(made)
      else { return }
      made.onEvent = { [weak self] event in self?.heard(event) }
      visuals = made
      visualsSurface = surface
      visualsFrame = nil
    }
    visuals?.show(on: display, fullScreen: fullScreen)
    rememberVisuals()
  }

  /// Closed as a person closes it, so it stays closed at the next launch.
  public func closeVisuals() {
    memory?.set(false, forKey: VisualsMemory.open)
    dropVisuals()
  }

  /// Put the window back if it was open when the app last quit, on the display it was on and full
  /// screen if it was: a projector's setup is the thing least worth rebuilding by hand every time.
  public func restoreVisuals() {
    guard let memory, memory.bool(forKey: VisualsMemory.open) else { return }
    showVisuals(
      on: memory.string(forKey: VisualsMemory.display),
      fullScreen: memory.bool(forKey: VisualsMemory.fullScreen))
  }

  /// Let go of the window, remembering nothing: as the app quits, or once a person has closed it.
  func dropVisuals() {
    visuals?.onEvent = nil
    visuals?.close()
    visuals = nil
    visualsSurface = nil
    visualsFrame = nil
  }

  func rememberVisuals() {
    guard let memory, let visuals else { return }
    memory.set(true, forKey: VisualsMemory.open)
    memory.set(visuals.display, forKey: VisualsMemory.display)
    memory.set(visuals.isFullScreen, forKey: VisualsMemory.fullScreen)
  }

  /// What the window hears. Space plays and stops, as it does in the main window: the visuals
  /// window is often the one in front, and the main window's keys do not reach it.
  func heard(_ event: VisualsEvent) {
    switch event {
    case .resized(let width, let height, _):
      visualsResized = (width, height)
    case .key(let key):
      if key.key == .space, key.isDown, !key.isRepeat { session.toggle() }
    case .moved:
      rememberVisuals()
    case .closed:
      memory?.set(false, forKey: VisualsMemory.open)
      visuals = nil
      visualsSurface = nil
      visualsFrame = nil
    }
  }

  /// The displays attached, asked again every couple of seconds rather than every frame: finding
  /// them is slow enough to feel, and plugging a projector in is not.
  var displaysNow: [String] {
    let now = HostTime.seconds(from: began, to: HostTime.now())
    if now - displaysAsked > 2 || now < displaysAsked {
      displays = window.displays
      displaysAsked = now
    }
    return displays
  }

  /// One frame of the scene into the visuals window, at its own shape and its display's scale:
  /// the frame the backdrop shows too, or nil while the window is shut.
  func drawVisuals(time: Double) throws -> (any GPUTarget)? {
    guard let visuals, let visualsSurface else { return nil }
    if let size = visualsResized {
      visualsResized = nil
      try visualsSurface.resize(width: size.width, height: size.height)
      visualsFrame = nil
    }
    let out: any GPUTarget
    if let visualsFrame {
      out = visualsFrame
    } else {
      out = try device.makeTarget(width: max(1, visualsSurface.width), height: max(1, visualsSurface.height))
      visualsFrame = out
    }
    scene.draw(session.sceneInput(time: time, pixelRatio: visuals.scale), into: out, on: device)
    presenter.present(out, into: try visualsSurface.target(), on: device)
    try visualsSurface.present()
    return out
  }
}
