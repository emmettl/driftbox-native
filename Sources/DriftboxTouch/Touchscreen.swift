import DriftboxCanvas
import DriftboxGPU
import DriftboxHelp
import DriftboxHost
import DriftboxInterface
import DriftboxRackSession
import DriftboxScenes
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation

/// Driftbox on a touch screen: the song's scene filling it, the controls over the scene, and the rest
/// of it the performance filter's pad. `Desktop`'s counterpart, and the same on every platform with
/// a touch screen: what a platform gives is a GPU device, the surface it draws to while there is one,
/// the typesetter, its fingers as pointer events in points, and — inside the session — its audio
/// and MIDI. There is no window to ask anything of, so nothing here waits on one: the platform
/// calls `draw` once for every refresh of the display, and `touch` for every finger.
///
/// A finger that lands on the controls is theirs until it lifts. The first finger anywhere else is
/// the pad's; a second one tapped while it is down steps on to the next scene.
@MainActor
public final class Touchscreen {
  public let session: Session
  /// The controls, over the scene.
  public let interface: Interface
  let device: any GPUDevice
  let typesetter: any Typesetter
  let presenter: Presenter
  /// The page the controls are drawn on, at the surface's every pixel.
  let canvas: Canvas
  /// The scene's own target, which may be drawn smaller than the surface (see `drawn`).
  var frame: (any GPUTarget)?
  /// Pixels to a point on the screen.
  public var scale: Float

  /// The scene chosen, or nil to show the song's own.
  public private(set) var chosenScene: String?
  var scene: any GPUScene
  public private(set) var sceneID: String
  let began = HostTime.now()

  /// The finger on the pad, and where, 0...1 from the bottom left.
  var padFinger: (id: Int, at: SIMD2<Float>)?
  /// Fingers down somewhere other than the pad or the controls: a second finger on the scene.
  var otherFingers: Set<Int> = []

  /// How long a finger rests on the controls before it asks what can be done with what it is on, as
  /// a secondary click does on a desktop.
  public static let longPress: Double = 0.5
  /// A finger resting on the controls: which, where, and since when, until it moves or lifts.
  var resting: (id: Int, at: SIMD2<Float>, since: Double)?
  /// Seconds on a clock of the touch screen's own; a test sets its own.
  var clock: () -> Double = { HostTime.seconds(from: 0, to: HostTime.now()) }
  /// A long press's menu, and where it was pressed, for the platform to show as its own: whatever
  /// is chosen from it goes to `choose`.
  public var onMenu: ((Menu, SIMD2<Float>) -> Void)?

  /// The rack, where the platform has one: shown in the groovebox's place, over no scene, while
  /// `showsRack` says. Each offers the way to the other, in the song's menu and the patches'.
  public private(set) var rack: RackInterface?
  public private(set) var showsRack = false
  /// A module of the rack asking for recordings — a Slice Lab's sample, a Key Atlas's set — for the
  /// platform to ask for with its own picker, and hand to `load`.
  public var onFiles: ((_ module: String, _ several: Bool) -> Void)?

  public init(
    session: Session, device: any GPUDevice, typesetter: any Typesetter, scale: Float, scene: String? = nil
  ) throws {
    self.session = session
    self.device = device
    self.typesetter = typesetter
    self.scale = max(1, scale)
    presenter = try Presenter(device: device)
    interface = Interface(session: session)
    interface.touch = true
    // The guides as a touchscreen's controls are: fingers, long presses and chips.
    interface.helpGuide = GrooveboxHelp.guide(for: .android)
    canvas = try Canvas(device: device, typesetter: typesetter)
    chosenScene = scene
    let type = GPUScenes.type(for: scene ?? session.song?.visual)
    self.scene = try type.init(device: device, typesetter: typesetter)
    sceneID = type.id
  }

  /// What a scene is drawn at on a surface `width` by `height` pixels of `scale` pixels to a point:
  /// no more than two pixels to a point, as a Mac's Retina display draws it, and scaled up to the
  /// surface as it is shown. A phone's screen is denser than that, and the scenes are soft enough
  /// not to show it: measured on a Fairphone 6, at its own 3, Frost took 21ms a frame at every
  /// pixel, and two others more than the display's 8.3. The controls are drawn at every pixel.
  public nonisolated static func drawn(width: Int, height: Int, scale: Float) -> (
    width: Int, height: Int, pixelRatio: Float
  ) {
    let shrink = min(1, 2 / max(scale, 1))
    return (
      max(1, Int((Float(width) * shrink).rounded())), max(1, Int((Float(height) * shrink).rounded())),
      max(scale, 1) * shrink
    )
  }

  // MARK: - A frame

  /// A frame into `surface`: the session caught up, the scene drawn from it, and the controls over it.
  public func draw(into surface: any GPUSurface) throws {
    session.tick()
    checkLongPress()
    if showsRack, let rack {
      // The rack covers the screen while it shows, and the scene waits, as on a desktop.
      let target = try surface.target()
      rack.size = SIMD2(Float(surface.width), Float(surface.height)) / scale
      try canvas.begin(width: target.width, height: target.height)
      canvas.scale(scale, scale)
      rack.draw(on: canvas)
      presenter.overlay(canvas.finish(), into: target, on: device)
      try surface.present()
      return
    }
    showScene()
    let drawn = Self.drawn(width: surface.width, height: surface.height, scale: scale)
    if frame?.width != drawn.width || frame?.height != drawn.height {
      frame = try device.makeTarget(width: drawn.width, height: drawn.height)
    }
    guard let frame else { return }
    let time = HostTime.seconds(from: began, to: HostTime.now())
    scene.draw(session.sceneInput(time: time, pixelRatio: drawn.pixelRatio), into: frame, on: device)
    let target = try surface.target()
    presenter.present(frame, into: target, on: device)
    interface.size = SIMD2(Float(surface.width), Float(surface.height)) / scale
    if interface.isShowing {
      try canvas.begin(width: target.width, height: target.height)
      canvas.scale(scale, scale)
      interface.draw(on: canvas)
      presenter.overlay(canvas.finish(), into: target, on: device)
    }
    try surface.present()
  }

  /// The scene there should be: the one chosen, or the song's own.
  func showScene() {
    let wanted = GPUScenes.type(for: chosenScene ?? session.song?.visual)
    guard wanted.id != sceneID else { return }
    guard let made = try? wanted.init(device: device, typesetter: typesetter) else { return }
    scene = made
    sceneID = wanted.id
  }

  /// The next scene there is, after the one showing.
  public func nextScene() {
    let all = GPUScenes.all
    let at = all.firstIndex { $0.id == sceneID } ?? 0
    chosenScene = all[(at + 1) % all.count].id
  }

  // MARK: - Fingers

  /// Put `rack` beside the groovebox: the song's menu offers it, and its patches' the way back.
  public func add(_ rack: RackSession) {
    let shown = RackInterface(rack: rack)
    shown.touch = true
    shown.helpGuide = RackHelp.guide(for: .android)
    shown.showGroovebox = { [weak self] in self?.show(rack: false) }
    interface.showRack = { [weak self] in self?.show(rack: true) }
    self.rack = shown
    // The MIDI that arrives is the rack's while it shows, and the groovebox's otherwise.
    session.midiListener = rack
    rack.inFront = showsRack
  }

  /// The rack in the groovebox's place, or back. Whatever a finger was doing on the one leaving is
  /// let go of, and the pad lifted. The one showing is played by a MIDI keyboard.
  public func show(rack showing: Bool) {
    guard showing != showsRack, rack != nil || !showing else { return }
    if let finger = padFinger {
      pad(PointerEvent(phase: .cancelled, id: finger.id, kind: .touch, location: .zero))
    }
    otherFingers = []
    resting = nil
    showsRack = showing
    rack?.rack.inFront = showing
    // Heard from the first time it is seen, if it was made asleep; and after, whichever shows.
    if showing { rack?.rack.wake() }
  }

  /// Recordings the platform's picker chose, as files, into the rack's `module`.
  @discardableResult
  public func load(_ files: [URL], into module: String) -> Bool {
    rack?.load(files, into: module) ?? false
  }

  /// What was chosen from the menu last shown: the rack's, while it shows, or the groovebox's.
  public func choose(_ id: String) {
    if showsRack, let rack { rack.choose(id) } else { interface.choose(id) }
  }

  /// Whether a command of the menu last shown can be chosen, and whether it shows as on.
  public func menuIsEnabled(_ id: String) -> Bool {
    showsRack ? rack?.menuIsEnabled(id) ?? false : interface.menuIsEnabled(id)
  }
  public func menuIsChecked(_ id: String) -> Bool {
    showsRack ? rack?.menuIsChecked(id) ?? false : interface.menuIsChecked(id)
  }

  /// A finger, in points from the top left of the surface.
  public func touch(_ event: PointerEvent) {
    var event = event
    event.kind = .touch
    if let rest = resting, rest.id == event.id {
      let moved = event.location - rest.at
      // Moved as far as a drag, or lifted: not resting any more.
      if event.phase != .moved || (moved * moved).sum() > 100 { resting = nil }
    }
    if showsRack, let rack {
      // The whole screen is the rack's; a finger that rests on it asks for its module's menu.
      rack.pointer(event)
      if event.phase == .began { resting = (event.id, event.location, clock()) }
      if let request = rack.takeMenuRequest() { onMenu?(request.menu, request.at) }
      if let module = rack.takeFileRequest() { onFiles?(module, rack.takesSeveral(module)) }
      return
    }
    if interface.pointer(event) {
      if event.phase == .began { resting = (event.id, event.location, clock()) }
      // A tap that asks for a menu — the song's chip — has it shown as a long press's is.
      if let request = interface.takeMenuRequest() { onMenu?(request.menu, request.at) }
      return
    }
    switch event.phase {
    case .began where padFinger == nil:
      pad(event)
    case .began:
      // Another finger while one is on the pad: a gesture, not a second pad.
      otherFingers.insert(event.id)
      if otherFingers.count == 1 { nextScene() }
    case .moved, .ended, .cancelled:
      if padFinger?.id == event.id {
        pad(event)
      } else {
        otherFingers.remove(event.id)
      }
    }
  }

  /// A finger that has rested long enough on the controls: the menu for what it is on, if that has
  /// one, handed to the platform, and the press given up, so that lifting it does not also do what
  /// it was on. Asked every frame, since a finger that rests says nothing until it moves.
  public func checkLongPress() {
    guard let rest = resting, clock() - rest.since >= Self.longPress else { return }
    resting = nil
    if showsRack, let rack {
      guard let menu = rack.menu(at: rest.at) else { return }
      rack.pointer(PointerEvent(phase: .cancelled, id: rest.id, kind: .touch, location: rest.at))
      onMenu?(menu, rest.at)
      return
    }
    guard !interface.performing, let menu = interface.menu(at: rest.at) else { return }
    _ = interface.pointer(PointerEvent(phase: .cancelled, id: rest.id, kind: .touch, location: rest.at))
    onMenu?(menu, rest.at)
  }

  /// The surface as the pad: 0...1 from the bottom left, as the engine and the scenes take it.
  func pad(_ event: PointerEvent) {
    let size = interface.size
    let at = SIMD2(event.location.x / max(1, size.x), 1 - event.location.y / max(1, size.y))
      .clamped(lowerBound: SIMD2(0, 0), upperBound: SIMD2(1, 1))
    switch event.phase {
    case .began, .moved:
      padFinger = (event.id, at)
      session.pad(x: Double(at.x), y: Double(at.y))
    case .ended, .cancelled:
      padFinger = nil
      session.padRelease()
    }
  }
}
