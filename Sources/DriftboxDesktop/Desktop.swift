import DriftboxCanvas
import DriftboxDocument
import DriftboxGPU
import DriftboxHelp
import DriftboxHost
import DriftboxInterface
import DriftboxMovie
import DriftboxRackSession
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
  var documentRequestPending = false
  var resized: (width: Int, height: Int)?

  /// The scene chosen from the View menu, or nil to show the song's own. A performance being
  /// recorded sees the switch too.
  public private(set) var chosenScene: String? {
    didSet { if chosenScene != oldValue { session.noteScene(chosenScene) } }
  }
  /// The scene being drawn, and which it is.
  var scene: any GPUScene
  public private(set) var sceneID: String
  let began = HostTime.now()
  /// The keyboard, played.
  var keys = KeyboardInstrument()
  /// Where the pointer is pressed on the pad, 0...1 from the bottom left, while it is.
  var touch: SIMD2<Float>?
  /// The rack, if the app has one: sounding beside the groovebox, and shown in its place while
  /// `showsRack`.
  public let rack: RackSession?
  public let rackInterface: RackInterface?
  /// While the rack shows, it is the one in front: the MIDI that arrives is its to play, as the
  /// Mac's is while its window is key.
  public internal(set) var showsRack = false {
    didSet { rack?.inFront = showsRack }
  }
  /// The audio being written by the last export, rendered off the main thread.
  var exporting: Task<Void, Never>?
  /// The movie being written, and how far it has got from 0 to 1; nil while none is.
  var movie: Task<Void, Never>?
  public internal(set) var movieProgress: Double?
  var movieStopped = false
  /// The size and rates movies are written in; smaller in a test.
  public var movieFormat = MovieFormat()
  /// Hosts without a movie encoder disable the movie and performance-recording commands.
  public var supportsMovies = true
  /// The visuals window, while it is open, and what draws into it.
  var visuals: (any ShellVisualsWindow)?
  var visualsSurface: (any GPUSurface)?
  var visualsFrame: (any GPUTarget)?
  var visualsResized: (width: Int, height: Int)?
  /// What makes the visuals window's surface: the platform's GPU on it. Nil, and no visuals window,
  /// where there is none.
  let makeVisualsSurface: ((any ShellVisualsWindow) throws -> any GPUSurface)?
  /// When what is on screen was last told to a screen reader.
  var describedAt = -Double.infinity
  /// The control the keyboard is on, while a screen reader runs, by its id; and where it was when
  /// last told, to ring it.
  var focused: String?
  var focusFrame: SIMD4<Float>?
  /// A guide open over the window.
  public internal(set) var help: HelpView?
  /// The song file last seen open, to notice another being opened or saved as.
  var lastFile: URL?
  /// The displays there were when last asked, and when.
  var displays: [String] = []
  var displaysAsked = -Double.infinity
  /// Where what is worth keeping between launches is kept — where the visuals window was — or
  /// nil for a desktop that keeps nothing, as a test's.
  public var memory: UserDefaults?
  /// What writes a movie's file: the platform's, unless a test says otherwise.
  var makeMovieWriter: @MainActor (URL, MovieFormat) throws -> any MovieWriter = Desktop.movieWriter

  public init(
    session: Session, window: any ShellWindow, device: any GPUDevice, surface: any GPUSurface,
    typesetter: any Typesetter, rack: RackSession? = nil,
    visualsSurface: ((any ShellVisualsWindow) throws -> any GPUSurface)? = nil
  ) throws {
    self.session = session
    makeVisualsSurface = visualsSurface
    self.rack = rack
    rackInterface = rack.map(RackInterface.init)
    // The rack lets go of a song it had linked here, as when another patch is opened in it.
    rack?.onUnlinkSong = { [weak session] in session?.unlinkRack() }
    // The MIDI that arrives is the rack's while it shows, and the groovebox's otherwise.
    session.midiListener = rack
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
    window.shouldClose = { [weak self] in self?.requestClose() ?? true }
    rack?.onLoadFailure = { [weak self] message in self?.window.tell(message) }
    refresh()
  }

  /// Until the window closes: the session caught up, the menus and the title brought up to date,
  /// and a frame of the scene, once for every refresh of the display.
  public func run() throws {
    defer {
      session.close()
      rack?.close()
      // Preserve the remembered open state while releasing the visuals window.
      dropVisuals()
    }
    try window.run { try drawFrame() }
  }

  // MARK: - A frame

  /// The ground the controls stand on while the visuals are stopped: the interface's own.
  static let ground = SIMD4<Float>(7 / 255, 4 / 255, 15 / 255, 1)

  func drawFrame() throws {
    session.tick()
    // The rack's meters and its last note, caught up whether it shows or not, as the Mac's are.
    rack?.tick()
    refresh()
    if let size = resized {
      resized = nil
      try surface.resize(width: size.width, height: size.height)
      frame = try device.makeTarget(width: max(1, size.width), height: max(1, size.height))
    }
    showScene()
    let time = HostTime.seconds(from: began, to: HostTime.now())
    // The visuals window, if one is open, draws the scene at its own shape; the backdrop shows its
    // frame, cropped to fill.
    let shown = try drawVisuals(time: time)
    var backdrop = frame
    // The rack covers the window while it shows: the scene waits. Behind the controls it runs if
    // the visuals are to run, and while the controls are away always: performing is what it is for.
    if !showsRack {
      if session.showsVisuals || !interface.isShowing {
        if let shown {
          backdrop = shown
        } else {
          scene.draw(session.sceneInput(time: time, pixelRatio: window.scale), into: frame, on: device)
        }
      } else {
        device.render(into: frame, clear: .colour(Self.ground)) { _ in }
      }
    }
    let target = try surface.target()
    presenter.present(backdrop, into: target, on: device, filling: backdrop !== frame)
    try drawInterface(into: target)
    try surface.present()
    describe(at: time)
  }

  /// The controls, drawn on a page the size of the window in its pixels, in points, and laid over
  /// the scene.
  func drawInterface(into target: any GPUTarget) throws {
    let points = SIMD2(Float(window.width), Float(window.height)) / window.scale
    interface.size = points
    let rack = showsRack ? rackInterface : nil
    guard rack != nil || interface.isShowing || help != nil else { return }
    try canvas.begin(width: target.width, height: target.height)
    canvas.scale(window.scale, window.scale)
    if let rack {
      rack.size = points
      rack.draw(on: canvas)
    } else if interface.isShowing {
      interface.draw(on: canvas)
    }
    // A guide over whichever it is.
    if let help {
      help.size = points
      help.draw(on: canvas)
    }
    drawFocus(on: canvas)
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
    if !documentRequestPending, let error = session.takeError() { window.tell(error) }
    noteOpenFile()
    // Typing is the rack's while it shows, as a routing's end is typed, and the controls' otherwise.
    let takesText = showsRack ? rackInterface?.takesText ?? false : interface.takesText
    if window.takesText != takesText { window.takesText = takesText }
    var title = showsRack ? rack.map(Self.title(for:)) ?? "Driftbox" : Self.title(for: session)
    if let activity { title = "\(activity) - \(title)" }
    if window.title != title { window.title = title }
    window.menuBar = DesktopMenus.bar(
      for: session, rack: rack, showsRack: showsRack, screenReader: keyboardNavigates,
      writingMovie: movieProgress != nil,
      displays: makeVisualsSurface == nil ? [] : displaysNow, visualsWindow: makeVisualsSurface != nil,
      recent: memory == nil ? nil : recentTitles)
  }

  /// As Windows' own programs title a document's window: its name, marked while it has changes
  /// not saved, and the program's name after it.
  static func title(for session: Session) -> String {
    guard session.song != nil else { return "Driftbox" }
    return "\(session.isEdited ? "*" : "")\(session.documentName) - Driftbox"
  }

  // MARK: - What the window hears

  func handle(_ event: ShellEvent) {
    if documentRequestPending {
      switch event {
      case .resized: break
      case .key(let key) where !key.isDown: break
      case .pointer(let pointer) where pointer.phase == .cancelled || pointer.phase == .ended: break
      default: return
      }
    }
    // With a screen reader, the keyboard moves between the controls first, and where a screen reader
    // moves it is the window's to keep.
    if case .key(let key) = event, navigate(key) { return }
    if case .accessibility(.focus(let id)) = event {
      focused = id
      describeNow()
      return
    }
    if handleHelp(event) { return }
    if showsRack, handleRack(event) { return }
    switch event {
    case .command(let id):
      perform(id)
    case .resized(let width, let height, _):
      resized = (width, height)
    case .pointer(let pointer) where pointer.button == 1:
      // The secondary button asks what can be done with what it is on, and is nothing to the pad.
      if pointer.phase == .began { contextMenu(at: pointer.location) }
    case .pointer(let pointer):
      // A press on the controls is theirs; anywhere else, the window is the pad.
      if !interface.pointer(pointer) { pad(pointer) }
    case .scroll(let scroll):
      _ = interface.scroll(scroll)
    case .dropped(let urls, _):
      openDropped(urls)
    case .key(let key):
      // A name being typed has every key; otherwise the keyboard is an instrument.
      if !interface.key(key) { _ = keys.play(key, on: session) }
      window.takesText = interface.takesText
    case .accessibility(let action):
      _ = interface.perform(action)
    case .describe:
      describeNow()
    }
  }

  /// The menu for what is at `point`, shown as the window shows one, and what is chosen from it done.
  func contextMenu(at point: SIMD2<Float>) {
    guard let menu = interface.menu(at: point) else { return }
    window.popUp(
      menu, at: point, isEnabled: { [interface] in interface.menuIsEnabled($0) },
      isChecked: { [interface] in interface.menuIsChecked($0) },
      completion: { [weak self] chosen in
        if let chosen { self?.interface.choose(chosen) }
      })
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
      replacingDocument { self.session.new() }
    case DesktopMenus.open:
      documentRequest { done in
        self.mayLoseChanges { allowed in
          guard allowed else {
            done()
            return
          }
          let songs = FileType(name: "Driftbox Song", extensions: SongFile.extensions)
          self.window.chooseFile(ofTypes: [songs]) { url in
            if let url { self.session.open(file: url) }
            done()
          }
        }
      }
    case DesktopMenus.save:
      documentRequest { done in self.save { _ in done() } }
    case DesktopMenus.saveAs:
      documentRequest { done in self.saveAs { _ in done() } }
    case DesktopMenus.exportMix:
      exportMix()
    case DesktopMenus.exportStems:
      exportStems()
    case DesktopMenus.exportMovie:
      exportMovie()
    case DesktopMenus.stopMovie:
      stopMovie()
    case DesktopMenus.record:
      toggleRecording()
    case DesktopMenus.exit:
      if requestClose() { window.close() }
    case DesktopMenus.undo: if showsRack, let rack { rack.undo() } else { session.undo() }
    case DesktopMenus.redo: if showsRack, let rack { rack.redo() } else { session.redo() }
    case DesktopMenus.toggle: if showsRack, let rack { rack.toggleRunning() } else { session.toggle() }
    case DesktopMenus.visualsWindow: if visualsOpen { closeVisuals() } else { showVisuals() }
    case DesktopMenus.clearRecent: clearRecent()
    case DesktopMenus.showRack: setShowsRack(!showsRack)
    case DesktopMenus.grooveboxGuide: showGuide(GrooveboxHelp.guide(for: .windows))
    case DesktopMenus.rackGuide: showGuide(RackHelp.guide(for: .windows))
    case DesktopMenus.rackSongFromGroovebox:
      guard let song = session.song else { return }
      rack?.openSong(song, name: session.documentName)
      setShowsRack(true)
    case DesktopMenus.rackBack: if showsRack { rack?.flip() }
    case DesktopMenus.start: session.seek(toStep: 0)
    case DesktopMenus.previousSection: session.skip(sections: -1)
    case DesktopMenus.nextSection: session.skip(sections: 1)
    case DesktopMenus.metronome: session.metronome.toggle()
    case DesktopMenus.recordAutomation: session.recordsAutomation.toggle()
    case DesktopMenus.clearAutomation: session.clearAutomation()
    case DesktopMenus.countIn: session.countsIn.toggle()
    case DesktopMenus.loop: session.loopSection()
    case DesktopMenus.clearLoop: session.loop = nil
    case DesktopMenus.nextScene: stepScene(by: 1)
    case DesktopMenus.previousScene: stepScene(by: -1)
    case DesktopMenus.songsScene: chosenScene = nil
    case DesktopMenus.controls: interface.isShowing.toggle()
    case DesktopMenus.visuals: session.showsVisuals.toggle()
    case DesktopMenus.systemOutput: session.outputDevice = nil
    case DesktopMenus.systemInput: rack?.inputDevice = nil
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
    if let module = DesktopMenus.value(id, after: DesktopMenus.rackAudioPrefix) {
      chooseRackAudio(into: module)
      return
    }
    if let songID = DesktopMenus.value(id, after: DesktopMenus.rackSongPrefix) {
      guard let entry = session.entries.first(where: { $0.id == songID }), let song = Catalogue.song(songID)
      else { return }
      rack?.openSong(song, name: entry.name)
      setShowsRack(true)
      return
    }
    if let patchID = DesktopMenus.value(id, after: DesktopMenus.patchPrefix) {
      guard let entry = PatchEntry.all.first(where: { $0.id == patchID }) else { return }
      rack?.open(entry)
      setShowsRack(true)
    } else if let entryID = DesktopMenus.value(id, after: DesktopMenus.songPrefix) {
      guard let entry = session.entries.first(where: { $0.id == entryID }) else { return }
      replacingDocument { self.session.open(entry) }
    } else if let sceneID = DesktopMenus.value(id, after: DesktopMenus.scenePrefix) {
      chosenScene = sceneID
    } else if let display = DesktopMenus.value(id, after: DesktopMenus.visualsOnPrefix) {
      showVisuals(on: display, fullScreen: true)
    } else if let index = DesktopMenus.value(id, after: DesktopMenus.recentPrefix).flatMap({ Int($0) }) {
      openRecent(index)
    } else if let device = DesktopMenus.value(id, after: DesktopMenus.outputPrefix) {
      session.outputDevice = device
    } else if let device = DesktopMenus.value(id, after: DesktopMenus.audioInputPrefix) {
      rack?.inputDevice = device
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
    guard !documentRequestPending else { return false }
    if let module = DesktopMenus.value(id, after: DesktopMenus.rackAudioPrefix) {
      return canLoadRackAudio(into: module)
    }
    return switch id {
    case DesktopMenus.undo: showsRack ? rack?.canUndo ?? false : session.canUndo
    case DesktopMenus.redo: showsRack ? rack?.canRedo ?? false : session.canRedo
    case DesktopMenus.toggle: showsRack || session.song != nil
    case DesktopMenus.showRack: rack != nil
    case DesktopMenus.save, DesktopMenus.saveAs, DesktopMenus.exportMix, DesktopMenus.exportStems,
      DesktopMenus.start,
      DesktopMenus.previousSection, DesktopMenus.nextSection, DesktopMenus.loop:
      session.song != nil
    case DesktopMenus.recordAutomation: session.song != nil
    case DesktopMenus.clearLoop: session.loop != nil
    case DesktopMenus.exportMovie: supportsMovies && session.song != nil && movieProgress == nil
    case DesktopMenus.stopMovie: movieProgress != nil
    case DesktopMenus.record:
      supportsMovies && session.song != nil && (session.isRecording || movieProgress == nil)
    case DesktopMenus.clearAutomation: session.song?.automation.isEmpty == false
    case DesktopMenus.noInputs, DesktopMenus.noOutputs, DesktopMenus.audioNote, DesktopMenus.noAudioTargets,
      DesktopMenus.noRecent:
      false
    default: true
    }
  }

  func isChecked(_ id: String) -> Bool {
    switch id {
    case DesktopMenus.metronome: return session.metronome
    case DesktopMenus.recordAutomation: return session.recordsAutomation
    case DesktopMenus.countIn: return session.countsIn
    case DesktopMenus.loop: return session.loop != nil
    case DesktopMenus.songsScene: return chosenScene == nil
    case DesktopMenus.controls: return interface.isShowing
    case DesktopMenus.showRack: return showsRack
    case DesktopMenus.rackBack: return rack?.flipped == true
    case DesktopMenus.systemOutput: return session.outputDevice == nil
    case DesktopMenus.systemInput: return rack?.inputDevice == nil
    case DesktopMenus.visuals: return session.showsVisuals
    case DesktopMenus.visualsWindow: return visualsOpen
    case DesktopMenus.listen: return session.listensToMIDI
    case DesktopMenus.followClock: return session.followsClock
    case DesktopMenus.sendClock: return session.sendsClock
    default: break
    }
    if let scene = DesktopMenus.value(id, after: DesktopMenus.scenePrefix) { return chosenScene == scene }
    if let display = DesktopMenus.value(id, after: DesktopMenus.visualsOnPrefix) {
      return visuals?.isFullScreen == true && visuals?.display == display
    }
    if let device = DesktopMenus.value(id, after: DesktopMenus.outputPrefix) {
      return session.outputDevice == device
    }
    if let device = DesktopMenus.value(id, after: DesktopMenus.audioInputPrefix) {
      return rack?.inputDevice == device
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
  func documentRequest(_ operation: (@escaping () -> Void) -> Void) {
    guard !documentRequestPending else { return }
    documentRequestPending = true
    operation { [weak self] in self?.documentRequestPending = false }
  }

  func replacingDocument(_ action: @escaping () -> Void) {
    documentRequest { done in
      mayLoseChanges { allowed in
        if allowed { action() }
        done()
      }
    }
  }

  /// Synchronous shells return their answer immediately; deferred shells close only after
  /// confirmation and a successful save. Repeated close requests cannot open another dialog.
  func requestClose() -> Bool {
    guard !documentRequestPending else { return false }
    var immediate: Bool?
    var requesting = true
    documentRequest { done in
      mayLoseChanges { [weak self] allowed in
        done()
        if requesting { immediate = allowed } else if allowed { self?.window.close() }
      }
    }
    requesting = false
    return immediate ?? false
  }

  func mayLoseChanges(completion: @escaping (Bool) -> Void) {
    guard session.isEdited else {
      completion(true)
      return
    }
    window.askToSave(session.documentName) { [weak self] answer in
      guard let self else {
        completion(false)
        return
      }
      switch answer {
      case .save: self.save(completion: completion)
      case .discard: completion(true)
      case .cancel: completion(false)
      }
    }
  }

  func save(completion: @escaping (Bool) -> Void) {
    guard session.fileURL != nil else {
      saveAs(completion: completion)
      return
    }
    completion(session.save())
  }

  func saveAs(completion: @escaping (Bool) -> Void) {
    guard session.song != nil else {
      completion(false)
      return
    }
    let type = FileType(name: "Driftbox Song", extensions: SongFile.extensions)
    window.chooseSaveLocation(for: type, name: session.documentName) { [weak self] url in
      guard let self, let url else {
        completion(false)
        return
      }
      completion(self.session.save(to: url))
    }
  }
}
