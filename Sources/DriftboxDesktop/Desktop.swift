import DriftboxCanvas
import DriftboxDocument
import DriftboxGPU
import DriftboxHost
import DriftboxInterface
import DriftboxScenes
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation

/// Driftbox on a desktop: a window with a menu bar, the song's scene filling it, the controls over
/// the scene, and the rest of it the performance filter's pad. Everything here is the same on every
/// platform with a `ShellWindow`;
/// what a platform gives is the window, a GPU device and the surface it draws to in that window,
/// the typesetter, and — inside the session — its audio and MIDI. The platform's own app is the one
/// place that chooses them, and then calls `run`.
///
/// The menus are data made from the session as it is, compared with what the window has and handed
/// over only when they differ. Settings are menu items the window ticks as their menu opens, so a
/// setting changing costs nothing until someone looks at it.
@MainActor
public final class Desktop {
  public let session: Session
  public let window: any ShellWindow
  let device: any GPUDevice
  let surface: any GPUSurface
  let typesetter: any Typesetter
  let presenter: Presenter
  /// The controls, over the scene, and the page they are drawn on.
  public let interface: Interface
  let canvas: Canvas
  var frame: any GPUTarget
  var resized: (width: Int, height: Int)?

  /// The scene chosen from the View menu, or nil to show the song's own.
  public private(set) var chosenScene: String?
  /// The scene being drawn, and which it is.
  var scene: any GPUScene
  public private(set) var sceneID: String
  let began = HostTime.now()
  /// Where the pointer is pressed on the pad, 0...1 from the bottom left, while it is.
  var touch: SIMD2<Float>?

  public init(
    session: Session, window: any ShellWindow, device: any GPUDevice, surface: any GPUSurface,
    typesetter: any Typesetter
  ) throws {
    self.session = session
    self.window = window
    self.device = device
    self.surface = surface
    self.typesetter = typesetter
    presenter = try Presenter(device: device)
    interface = Interface(session: session)
    canvas = try Canvas(device: device, typesetter: typesetter)
    frame = try device.makeTarget(width: max(1, surface.width), height: max(1, surface.height))
    let type = GPUScenes.type(for: session.song?.visual)
    scene = try type.init(device: device, typesetter: typesetter)
    sceneID = type.id

    // Weakly: the window is the desktop's, and a window that outlived it would ask nothing of it.
    window.onEvent = { [weak self] event in self?.handle(event) }
    window.isEnabled = { [weak self] id in self?.isEnabled(id) ?? false }
    window.isChecked = { [weak self] id in self?.isChecked(id) ?? false }
    window.shouldClose = { [weak self] in self?.mayLoseChanges() ?? true }
    refresh()
  }

  /// Until the window closes: the session caught up, the menus and the title brought up to date,
  /// and a frame of the scene, once for every refresh of the display.
  public func run() throws {
    try window.run { try drawFrame() }
    session.close()
  }

  // MARK: - A frame

  func drawFrame() throws {
    session.tick()
    refresh()
    if let size = resized {
      resized = nil
      try surface.resize(width: size.width, height: size.height)
      frame = try device.makeTarget(width: max(1, size.width), height: max(1, size.height))
    }
    showScene()
    let time = HostTime.seconds(from: began, to: HostTime.now())
    scene.draw(session.sceneInput(time: time, pixelRatio: window.scale), into: frame, on: device)
    let target = try surface.target()
    presenter.present(frame, into: target, on: device)
    try drawInterface(into: target)
    try surface.present()
  }

  /// The controls, drawn on a page the size of the window in its pixels, in points, and laid over
  /// the scene.
  func drawInterface(into target: any GPUTarget) throws {
    interface.size = SIMD2(Float(window.width), Float(window.height)) / window.scale
    guard interface.isShowing else { return }
    try canvas.begin(width: target.width, height: target.height)
    canvas.scale(window.scale, window.scale)
    interface.draw(on: canvas)
    presenter.overlay(canvas.finish(), into: target, on: device)
  }

  /// The scene there should be: the one chosen, or the song's own, or Pulse while there is no
  /// scene of that name on the layer yet.
  func showScene() {
    let wanted = GPUScenes.type(for: chosenScene ?? session.song?.visual)
    guard wanted.id != sceneID else { return }
    guard let made = try? wanted.init(device: device, typesetter: typesetter) else { return }
    scene = made
    sceneID = wanted.id
  }

  /// The window's title and menus as the session now is. Each is handed over only when it differs
  /// from what the window has, which the window checks itself for the menus.
  func refresh() {
    let title = Self.title(for: session)
    if window.title != title { window.title = title }
    window.menuBar = DesktopMenus.bar(for: session)
  }

  /// As Windows' own programs title a document's window: its name, marked while it has changes
  /// not saved, and the program's name after it.
  static func title(for session: Session) -> String {
    guard session.song != nil else { return "Driftbox" }
    return "\(session.isEdited ? "*" : "")\(session.documentName) - Driftbox"
  }

  // MARK: - What the window hears

  func handle(_ event: ShellEvent) {
    switch event {
    case .command(let id):
      perform(id)
    case .resized(let width, let height, _):
      resized = (width, height)
    case .pointer(let pointer):
      // A press on the controls is theirs; anywhere else, the window is the pad.
      if !interface.pointer(pointer) { pad(pointer) }
    default:
      break
    }
  }

  /// The window as the pad: 0...1 from the bottom left, as the engine and the scenes take it.
  func pad(_ pointer: PointerEvent) {
    let size = SIMD2(Float(window.width), Float(window.height)) / window.scale
    let at = SIMD2(pointer.location.x / max(1, size.x), 1 - pointer.location.y / max(1, size.y))
      .clamped(lowerBound: SIMD2(0, 0), upperBound: SIMD2(1, 1))
    switch pointer.phase {
    case .began:
      touch = at
    case .moved where touch != nil:
      touch = at
    case .ended, .cancelled:
      touch = nil
      session.padRelease()
      return
    default:
      return
    }
    session.pad(x: Double(at.x), y: Double(at.y))
  }

  // MARK: - Commands

  func perform(_ id: String) {
    switch id {
    case DesktopMenus.new:
      guard mayLoseChanges() else { return }
      session.new()
    case DesktopMenus.open:
      guard mayLoseChanges() else { return }
      let songs = FileType(name: "Driftbox Song", extensions: SongFile.extensions)
      if let url = window.chooseFile(ofTypes: [songs]) { session.open(file: url) }
    case DesktopMenus.save:
      _ = save()
    case DesktopMenus.saveAs:
      _ = saveAs()
    case DesktopMenus.exit:
      if mayLoseChanges() { window.close() }
    case DesktopMenus.undo: session.undo()
    case DesktopMenus.redo: session.redo()
    case DesktopMenus.toggle: session.toggle()
    case DesktopMenus.start: session.seek(toStep: 0)
    case DesktopMenus.previousSection: session.skip(sections: -1)
    case DesktopMenus.nextSection: session.skip(sections: 1)
    case DesktopMenus.metronome: session.metronome.toggle()
    case DesktopMenus.countIn: session.countsIn.toggle()
    case DesktopMenus.loop: session.loopSection()
    case DesktopMenus.nextScene: stepScene(by: 1)
    case DesktopMenus.previousScene: stepScene(by: -1)
    case DesktopMenus.songsScene: chosenScene = nil
    case DesktopMenus.controls: interface.isShowing.toggle()
    case DesktopMenus.systemOutput: session.outputDevice = nil
    case DesktopMenus.listen: session.listensToMIDI.toggle()
    case DesktopMenus.followClock: session.followsClock.toggle()
    case DesktopMenus.sendClock: session.sendsClock.toggle()
    default:
      performNamed(id)
    }
  }

  /// The commands that carry what they are about in their id: a song, a scene, a device, a source,
  /// a destination.
  func performNamed(_ id: String) {
    if let entryID = DesktopMenus.value(id, after: DesktopMenus.songPrefix) {
      guard let entry = session.entries.first(where: { $0.id == entryID }), mayLoseChanges() else { return }
      session.open(entry)
    } else if let sceneID = DesktopMenus.value(id, after: DesktopMenus.scenePrefix) {
      chosenScene = sceneID
    } else if let device = DesktopMenus.value(id, after: DesktopMenus.outputPrefix) {
      session.outputDevice = device
    } else if let source = DesktopMenus.value(id, after: DesktopMenus.inputPrefix) {
      if session.ignoredMIDISources.contains(source) {
        session.ignoredMIDISources.remove(source)
      } else {
        session.ignoredMIDISources.insert(source)
      }
    } else if let port = DesktopMenus.value(id, after: DesktopMenus.clockPrefix) {
      session.clockDestination = .port(port)
    }
  }

  /// The next or previous scene on the layer from the one showing, chosen from then on.
  func stepScene(by offset: Int) {
    let all = GPUScenes.all
    let at = all.firstIndex { $0.id == sceneID } ?? 0
    chosenScene = all[(at + offset + all.count) % all.count].id
  }

  func isEnabled(_ id: String) -> Bool {
    switch id {
    case DesktopMenus.undo: session.canUndo
    case DesktopMenus.redo: session.canRedo
    case DesktopMenus.save, DesktopMenus.saveAs, DesktopMenus.toggle, DesktopMenus.start,
      DesktopMenus.previousSection, DesktopMenus.nextSection, DesktopMenus.loop:
      session.song != nil
    case DesktopMenus.noInputs, DesktopMenus.noOutputs: false
    default: true
    }
  }

  func isChecked(_ id: String) -> Bool {
    switch id {
    case DesktopMenus.metronome: return session.metronome
    case DesktopMenus.countIn: return session.countsIn
    case DesktopMenus.loop: return session.loop != nil
    case DesktopMenus.songsScene: return chosenScene == nil
    case DesktopMenus.controls: return interface.isShowing
    case DesktopMenus.systemOutput: return session.outputDevice == nil
    case DesktopMenus.listen: return session.listensToMIDI
    case DesktopMenus.followClock: return session.followsClock
    case DesktopMenus.sendClock: return session.sendsClock
    default: break
    }
    if let scene = DesktopMenus.value(id, after: DesktopMenus.scenePrefix) { return chosenScene == scene }
    if let device = DesktopMenus.value(id, after: DesktopMenus.outputPrefix) {
      return session.outputDevice == device
    }
    if let source = DesktopMenus.value(id, after: DesktopMenus.inputPrefix) {
      return !session.ignoredMIDISources.contains(source)
    }
    if let port = DesktopMenus.value(id, after: DesktopMenus.clockPrefix) {
      return session.clockDestination == .port(port)
    }
    if let entry = DesktopMenus.value(id, after: DesktopMenus.songPrefix) {
      return session.current?.id == entry
    }
    return false
  }

  // MARK: - Saving

  /// Whether what is in the window may go: yes when nothing has changed, and otherwise as the
  /// person asked says — saved first, thrown away, or not after all.
  func mayLoseChanges() -> Bool {
    guard session.isEdited else { return true }
    switch window.askToSave(session.documentName) {
    case .save: return save()
    case .discard: return true
    case .cancel: return false
    }
  }

  /// Save where the song came from, or ask where when it came from nowhere. False if it was not.
  func save() -> Bool {
    guard session.fileURL != nil else { return saveAs() }
    session.save()
    return !session.isEdited
  }

  func saveAs() -> Bool {
    guard session.song != nil else { return false }
    let type = FileType(name: "Driftbox Song", extensions: SongFile.extensions)
    guard let url = window.chooseSaveLocation(for: type, name: session.documentName) else { return false }
    session.save(to: url)
    return !session.isEdited
  }
}
