import DriftboxDocument
import DriftboxGPU
import DriftboxHost
import DriftboxRackSession
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation
import Testing

@testable import DriftboxDesktop

#if os(Windows)
  import DriftboxGPUD3D11
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#elseif os(Linux)
  import DriftboxGPUGLES
#endif

/// A window that is only what the app asks of one: it keeps its title and menus, answers the save
/// question and the panels as a test tells it to, and runs nothing.
@MainActor
final class StandInWindow: ShellWindow {
  var width = 320
  var height = 180
  var scale: Float = 1
  var title = ""
  var menuBar: MenuBar?
  var onEvent: ((ShellEvent) -> Void)?
  var isEnabled: ((String) -> Bool)?
  var isChecked: ((String) -> Bool)?
  var shouldClose: (() -> Bool)?
  var takesText = false
  var closed = false
  var saveAnswer = SaveAnswer.cancel
  var asked: [String] = []
  var chosenFile: URL?
  var saveLocation: URL?

  func run(frame: () throws -> Void) throws {}
  func close() { closed = true }
  nonisolated func post(_ work: @escaping @Sendable () -> Void) {}
  func chooseFile(ofTypes types: [FileType]) -> URL? { chosenFile }
  func chooseSaveLocation(for type: FileType, name: String) -> URL? { saveLocation }
  func askToSave(_ name: String) -> SaveAnswer {
    asked.append(name)
    return saveAnswer
  }
  /// The context menus shown, and what the next one has chosen from it, if that can be chosen.
  var popped: [Menu] = []
  var popUpChoice: String?
  func popUp(
    _ menu: Menu, at point: SIMD2<Float>, isEnabled: (String) -> Bool, isChecked: (String) -> Bool
  ) -> String? {
    popped.append(menu)
    guard let choice = popUpChoice, menu.commands.contains(where: { $0.id == choice }), isEnabled(choice)
    else {
      return nil
    }
    return choice
  }

  /// A command as the window sends one: only while enabled.
  func choose(_ id: String) {
    guard isEnabled?(id) ?? true else { return }
    onEvent?(.command(id))
  }

  /// Every command in the menus, by id.
  var commandIDs: [String] { menuBar?.commands.map(\.id) ?? [] }
  func title(of id: String) -> String? { menuBar?.commands.first { $0.id == id }?.title }
}

/// A surface that is only a target the size it was last told.
final class StandInSurface: GPUSurface {
  let device: any GPUDevice
  var width: Int
  var height: Int
  var presented = 0
  init(device: any GPUDevice, width: Int, height: Int) {
    self.device = device
    self.width = width
    self.height = height
  }
  func resize(width: Int, height: Int) throws {
    self.width = width
    self.height = height
  }
  func target() throws -> any GPUTarget { try device.makeTarget(width: width, height: height) }
  func present() throws { presented += 1 }
}

/// The desktop app, the same on every platform with a window: its menus made from the session,
/// its commands, its title, its care over unsaved work, and its frames. On every GPU this platform
/// has, since a frame is part of what it does.
@MainActor
struct DesktopTests {
  static func devices() throws -> [any GPUDevice] {
    #if os(Windows)
      return [try D3D11Device(driver: .software)]
    #elseif canImport(Metal)
      return MTLCreateSystemDefaultDevice() == nil ? [] : [try MetalDevice()]
    #elseif os(Linux)
      return [try GLESDevice()]
    #else
      return []
    #endif
  }

  /// A desktop on a session of its own, with no sound, no cables and no memory.
  static func desktop(on device: any GPUDevice) throws -> (Desktop, StandInWindow, StandInSurface) {
    let window = StandInWindow()
    let surface = StandInSurface(device: device, width: 320, height: 180)
    let session = Session(host: EngineHost(sampleRate: 48000))
    let desktop = try Desktop(
      session: session, window: window, device: device, surface: surface, typesetter: NoTypesetter())
    return (desktop, window, surface)
  }

  static func song() -> Song {
    var pattern = DriftboxSeq.Pattern(id: "p", name: "Pattern 1", length: 16)
    pattern.tracks["909.bd"] = [StepValue](repeating: .on, count: 16)
    var song = Song(bpm: 120, patterns: [pattern])
    song.chain = [ChainStep(pattern: pattern.id), ChainStep(pattern: pattern.id)]
    song.visual = "frost"
    return song
  }

  /// With nothing open, the window is the application: its name, and nothing to save or play.
  @Test func withNoSongTheWindowIsTheApplication() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      defer { withExtendedLifetime(desktop) {} }
      #expect(window.title == "Driftbox")
      #expect(window.isEnabled?(DesktopMenus.save) == false)
      #expect(window.isEnabled?(DesktopMenus.toggle) == false)
      #expect(window.isEnabled?(DesktopMenus.undo) == false)
      #expect(window.isEnabled?(DesktopMenus.open) == true)
      #expect(
        window.commandIDs.contains(DesktopMenus.songPrefix + "acid"), "every catalogue song is on offer")
    }
  }

  /// A catalogue song chosen from the menu opens, names the window, and brings its scene.
  @Test func aCatalogueSongOpensWithItsScene() throws {
    for device in try Self.devices() {
      let (desktop, window, surface) = try Self.desktop(on: device)
      window.choose(DesktopMenus.songPrefix + "hothouse")
      try desktop.drawFrame()
      #expect(window.title == "Hothouse - Driftbox")
      #expect(desktop.sceneID == "hothouse")
      #expect(window.isChecked?(DesktopMenus.songPrefix + "hothouse") == true)
      #expect(surface.presented == 1)
    }
  }

  /// An edit marks the title and names the Edit menu's undo; undoing it takes both back.
  @Test func editsAreMarkedAndUndoneByName() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        let url = directory.appendingPathComponent("Groove.driftbox")
        try Data(SongCodec.encode(Self.song()).utf8).write(to: url)
        window.chosenFile = url
        window.choose(DesktopMenus.open)
        try desktop.drawFrame()
        #expect(window.title == "Groove - Driftbox")

        desktop.session.edit("Set Tempo") { $0.bpm = 128 }
        try desktop.drawFrame()
        #expect(window.title == "*Groove - Driftbox")
        #expect(window.title(of: DesktopMenus.undo) == "Undo Set Tempo")
        #expect(window.isEnabled?(DesktopMenus.undo) == true)

        window.choose(DesktopMenus.undo)
        try desktop.drawFrame()
        #expect(window.title == "Groove - Driftbox")
        #expect(window.title(of: DesktopMenus.redo) == "Redo Set Tempo")
      }
    }
  }

  /// Closing, opening or starting afresh over changes asks first: saved where the song came from,
  /// thrown away, or not done at all.
  @Test func unsavedWorkIsAskedAbout() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        let url = directory.appendingPathComponent("Groove.driftbox")
        try Data(SongCodec.encode(Self.song()).utf8).write(to: url)
        window.chosenFile = url
        window.choose(DesktopMenus.open)

        #expect(window.shouldClose?() == true, "nothing changed, nothing asked")
        #expect(window.asked.isEmpty)

        desktop.session.edit("Set Tempo") { $0.bpm = 128 }
        window.saveAnswer = .cancel
        #expect(window.shouldClose?() == false, "thought again")
        window.choose(DesktopMenus.new)
        #expect(desktop.session.current?.name == "Groove", "and New did nothing")
        #expect(window.asked == ["Groove", "Groove"])

        window.saveAnswer = .save
        #expect(window.shouldClose?() == true, "saved, then closed")
        let written = SongCodec.decode(String(decoding: try Data(contentsOf: url), as: UTF8.self))
        #expect(written?.bpm == 128)

        desktop.session.edit("Set Tempo") { $0.bpm = 90 }
        window.saveAnswer = .discard
        window.choose(DesktopMenus.exit)
        #expect(window.closed, "thrown away, then closed")
      }
    }
  }

  /// A new song has nowhere to be saved, so saving it asks where; and not saving anywhere is not
  /// having saved.
  @Test func aNewSongIsSavedWhereItIsAskedTo() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        window.choose(DesktopMenus.new)
        desktop.session.edit("Set Tempo") { $0.bpm = 100 }
        window.saveLocation = nil
        window.saveAnswer = .save
        #expect(window.shouldClose?() == false, "no place chosen, so not saved and not closed")

        let url = directory.appendingPathComponent("Fresh.driftbox")
        window.saveLocation = url
        window.choose(DesktopMenus.save)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try desktop.drawFrame()
        #expect(window.title == "Fresh - Driftbox")
      }
    }
  }

  /// The settings are menu items, ticked as the session has them, and choosing one changes it.
  @Test func settingsAreTickedAndToggled() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      #expect(window.isChecked?(DesktopMenus.metronome) == false)
      window.choose(DesktopMenus.metronome)
      #expect(desktop.session.metronome)
      #expect(window.isChecked?(DesktopMenus.metronome) == true)

      #expect(window.isChecked?(DesktopMenus.systemOutput) == true)
      window.choose(DesktopMenus.outputPrefix + "{speakers}")
      #expect(desktop.session.outputDevice == "{speakers}")
      #expect(window.isChecked?(DesktopMenus.outputPrefix + "{speakers}") == true)
      #expect(window.isChecked?(DesktopMenus.systemOutput) == false)

      window.choose(DesktopMenus.sendClock)
      #expect(desktop.session.sendsClock)
      window.choose(DesktopMenus.followClock)
      #expect(desktop.session.followsClock)
      #expect(window.isChecked?(DesktopMenus.sendClock) == false, "following and sending are never both")

      #expect(window.isEnabled?(DesktopMenus.noInputs) == false)
      #expect(window.isChecked?(DesktopMenus.noInputs) == false)
    }
  }

  /// The View menu chooses a scene over the song's, steps through them, and gives the song's back.
  @Test func aSceneIsChosenOrTheSongs() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      window.choose(DesktopMenus.songPrefix + "hothouse")
      try desktop.drawFrame()
      window.choose(DesktopMenus.scenePrefix + "orrery")
      try desktop.drawFrame()
      #expect(desktop.sceneID == "orrery")
      #expect(window.isChecked?(DesktopMenus.scenePrefix + "orrery") == true)
      #expect(window.isChecked?(DesktopMenus.songsScene) == false)
      window.choose(DesktopMenus.nextScene)
      try desktop.drawFrame()
      #expect(desktop.sceneID != "orrery")
      window.choose(DesktopMenus.songsScene)
      try desktop.drawFrame()
      #expect(desktop.sceneID == "hothouse")
    }
  }

  /// The window is the pad, away from the controls: pressed, the filter moves and the scene sees
  /// the finger; let go, both let go.
  @Test func theWindowIsThePad() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      window.onEvent?(.pointer(PointerEvent(phase: .began, id: 0, kind: .mouse, location: SIMD2(80, 135))))
      #expect(desktop.session.padTouch == SIMD2(0.25, 0.25))
      window.onEvent?(.pointer(PointerEvent(phase: .ended, id: 0, kind: .mouse, location: SIMD2(80, 135))))
      #expect(desktop.session.padTouch == nil)
    }
  }

  /// A press on the controls is theirs and not the pad's; with the controls hidden, from the View
  /// menu, the whole window is the pad again. A frame draws them over the scene, or does not.
  @Test func theControlsAreOverThePad() throws {
    for device in try Self.devices() {
      let (desktop, window, surface) = try Self.desktop(on: device)
      try desktop.drawFrame()
      let onTheBar = SIMD2<Float>(250, 30)
      window.onEvent?(.pointer(PointerEvent(phase: .began, location: onTheBar)))
      #expect(desktop.session.padTouch == nil)
      window.onEvent?(.pointer(PointerEvent(phase: .ended, location: onTheBar)))

      #expect(window.isChecked?(DesktopMenus.controls) == true)
      window.choose(DesktopMenus.controls)
      #expect(!desktop.interface.isShowing)
      #expect(window.isChecked?(DesktopMenus.controls) == false)
      window.onEvent?(.pointer(PointerEvent(phase: .began, location: onTheBar)))
      #expect(desktop.session.padTouch != nil)
      window.onEvent?(.pointer(PointerEvent(phase: .ended, location: onTheBar)))
      try desktop.drawFrame()
      #expect(surface.presented == 2)
    }
  }

  /// The secondary button on a lane shows the lane's menu as the window shows one, and what is
  /// chosen from it is done; it is nothing to the pad.
  @Test func aLanesMenuIsTheWindows() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        let url = directory.appendingPathComponent("Groove.driftbox")
        try Data(SongCodec.encode(Self.song()).utf8).write(to: url)
        window.chosenFile = url
        window.choose(DesktopMenus.open)
        window.width = 1280
        window.height = 720
        try desktop.drawFrame()
        let lane = try #require(desktop.interface.layout.lanes.first)
        let at = SIMD2(lane.frame.x + 200, lane.frame.y + lane.frame.height / 2)

        window.popUpChoice = "lane.clear"
        window.onEvent?(.pointer(PointerEvent(phase: .began, location: at, button: 1)))
        window.onEvent?(.pointer(PointerEvent(phase: .ended, location: at, button: 1)))
        #expect(window.popped.first?.title == "Bass Drum")
        #expect(window.popped.first?.commands.map(\.id).contains("lane.paste") == true)
        #expect(desktop.session.shownPattern?.tracks["909.bd"] == nil, "cleared, the lane goes")
        #expect(desktop.session.undoTitle == "Undo Clear Lane")
        #expect(desktop.session.padTouch == nil)
      }
    }
  }

  /// With a rack, the Rack menu shows it in the groovebox's place and opens its patches; while it
  /// shows, the window's title, its Edit menu, its Space and its pointer are the rack's; and the
  /// groovebox comes back as it was. Without one, there is no Rack menu.
  @Test func theRackShowsInTheGrooveboxesPlace() throws {
    for device in try Self.devices() {
      let (plain, plainWindow, _) = try Self.desktop(on: device)
      defer { withExtendedLifetime(plain) {} }
      #expect(!plainWindow.commandIDs.contains(DesktopMenus.showRack))

      let window = StandInWindow()
      let surface = StandInSurface(device: device, width: 320, height: 180)
      let desktop = try Desktop(
        session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
        surface: surface,
        typesetter: NoTypesetter(), rack: RackSession())
      let rack = try #require(desktop.rack)
      #expect(window.commandIDs.contains(DesktopMenus.patchPrefix + "acid"))
      #expect(window.isChecked?(DesktopMenus.showRack) == false)

      window.choose(DesktopMenus.showRack)
      #expect(desktop.showsRack && window.isChecked?(DesktopMenus.showRack) == true)
      try desktop.drawFrame()
      #expect(window.title == "\(rack.name) - Driftbox Rack")
      #expect(surface.presented == 1)

      window.choose(DesktopMenus.toggle)
      #expect(rack.running, "Space is the rack's")
      #expect(!desktop.session.isPlaying)
      window.onEvent?(.pointer(PointerEvent(phase: .began, location: SIMD2(160, 170))))
      window.onEvent?(.pointer(PointerEvent(phase: .ended, location: SIMD2(160, 170))))
      #expect(desktop.session.padTouch == nil, "and not the pad's")

      window.choose(DesktopMenus.patchPrefix + "acid")
      #expect(rack.name == PatchEntry.all.first { $0.id == "acid" }?.name)
      rack.setTempo(99)
      try desktop.drawFrame()
      #expect(window.title(of: DesktopMenus.undo) == "Undo Set Tempo")
      window.choose(DesktopMenus.undo)
      #expect(rack.tempo != 99, "undone in the rack")

      #expect(
        window.commandIDs.contains(DesktopMenus.rackBack)
          && !window.commandIDs.contains(DesktopMenus.controls))
      window.choose(DesktopMenus.rackBack)
      try desktop.drawFrame()
      #expect(rack.flipped && window.isChecked?(DesktopMenus.rackBack) == true, "Tab turns the rack round")

      window.choose(DesktopMenus.showRack)
      try desktop.drawFrame()
      #expect(!desktop.showsRack && window.title == "Driftbox")
    }
  }

  /// The keyboard the window hears is the instrument's.
  @Test func theKeysReachTheInstrument() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      window.onEvent?(.key(KeyEvent(key: .character("x"))))
      #expect(desktop.keys.octave == 1)
    }
  }

  /// While a name is being typed the keys are the name's, not the instrument's, and the window is
  /// told it is taking text, so that its shortcuts leave them be.
  @Test func aNameBeingTypedHasTheKeys() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        let url = directory.appendingPathComponent("Groove.driftbox")
        try Data(SongCodec.encode(Self.song()).utf8).write(to: url)
        window.chosenFile = url
        window.choose(DesktopMenus.open)
        desktop.interface.rename(pattern: "p")
        try desktop.drawFrame()
        #expect(window.takesText)
        window.onEvent?(.key(KeyEvent(key: .character("x"))))
        #expect(desktop.keys.octave == 0, "not the instrument's")
        window.onEvent?(.key(KeyEvent(key: .return)))
        #expect(!window.takesText)
        #expect(desktop.session.song?.pattern(id: "p")?.name == "Pattern 1x")
      }
    }
  }

  /// A resize reaches the surface at the next frame.
  @Test func aResizeReachesTheSurface() throws {
    for device in try Self.devices() {
      let (desktop, window, surface) = try Self.desktop(on: device)
      window.onEvent?(.resized(width: 400, height: 300, scale: 1))
      try desktop.drawFrame()
      #expect(surface.width == 400 && surface.height == 300)
    }
  }
}

/// Somewhere of its own for a test that writes files, taken away again afterwards.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("driftbox-desktop-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try body(directory)
}
