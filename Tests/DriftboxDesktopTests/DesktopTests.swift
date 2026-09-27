import DriftboxDocument
import DriftboxEngine
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
  var defersDialogs = false
  var pendingQuestion: ((SaveAnswer) -> Void)?
  var pendingSave: ((URL?) -> Void)?
  var pendingOpen: ((URL?) -> Void)?
  var pendingFolder: ((URL?) -> Void)?
  func chooseFolder(title: String, button: String, completion: @escaping (URL?) -> Void) {
    if defersDialogs { pendingFolder = completion } else { completion(folder) }
  }
  var pendingMultiple: (([URL]) -> Void)?
  var requestedTypes: [FileType] = []
  func chooseFiles(ofTypes types: [FileType], completion: @escaping ([URL]) -> Void) {
    requestedTypes = types
    if defersDialogs { pendingMultiple = completion } else { completion(chosenFile.map { [$0] } ?? []) }
  }
  func chooseFile(ofTypes types: [FileType], completion: @escaping (URL?) -> Void) {
    requestedTypes = types
    if defersDialogs { pendingOpen = completion } else { completion(chooseFile(ofTypes: types)) }
  }
  func chooseSaveLocation(for type: FileType, name: String, completion: @escaping (URL?) -> Void) {
    if defersDialogs {
      pendingSave = completion
    } else {
      completion(chooseSaveLocation(for: type, name: name))
    }
  }
  func askToSave(_ name: String, completion: @escaping (SaveAnswer) -> Void) {
    if defersDialogs {
      asked.append(name)
      pendingQuestion = completion
    } else {
      completion(askToSave(name))
    }
  }
  var folder: URL?

  func run(frame: () throws -> Void) throws {}
  func close() { closed = true }
  nonisolated func post(_ work: @escaping @Sendable () -> Void) {}
  func chooseFile(ofTypes types: [FileType]) -> URL? { chosenFile }
  func chooseSaveLocation(for type: FileType, name: String) -> URL? { saveLocation }
  func chooseFolder(title: String, button: String) -> URL? { folder }
  var revealed: [URL] = []
  func reveal(_ url: URL) { revealed.append(url) }
  var told: [String] = []
  func tell(_ message: String) { told.append(message) }
  var displays: [String] = []
  var recents: [URL] = []
  func addToRecents(_ url: URL) { recents.append(url) }
  /// Whether a screen reader is reading it, as a test says, and what it was told.
  var isDescribed = false
  var described: [AccessibilityNode] = []
  func describe(_ root: AccessibilityNode) { described.append(root) }
  var screenReaderIsOn = false
  /// Where the keyboard was said to be, each time it was.
  var focusedIds: [String?] = []
  func focus(_ id: String?) { focusedIds.append(id) }
  /// The visuals windows made, the last the one in use.
  var visualsWindows: [StandInVisualsWindow] = []
  func makeVisualsWindow() -> (any ShellVisualsWindow)? {
    let made = StandInVisualsWindow()
    visualsWindows.append(made)
    return made
  }
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

/// A visuals window that keeps where it was sent, and is told what a person does to it.
@MainActor
final class StandInVisualsWindow: ShellVisualsWindow {
  var width = 640
  var height = 360
  var scale: Float = 1
  var isFullScreen = false
  var display: String?
  var onEvent: ((VisualsEvent) -> Void)?
  var closed = false
  func show(on display: String?, fullScreen: Bool) {
    if let display { self.display = display }
    isFullScreen = fullScreen
  }
  func close() { closed = true }
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

  /// View's Run the Visuals is the session's, ticked as it is; and the Audio menu names a device
  /// chosen and not plugged in, ticked, rather than ticking nothing.
  @Test func theVisualsAndTheSoundAreSettings() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      #expect(window.commandIDs.contains(DesktopMenus.visuals))
      #expect(window.isChecked?(DesktopMenus.visuals) == desktop.session.showsVisuals)
      let was = desktop.session.showsVisuals
      window.choose(DesktopMenus.visuals)
      #expect(desktop.session.showsVisuals == !was)
      try desktop.drawFrame()
      window.choose(DesktopMenus.visuals)

      desktop.session.outputDevice = "gone"
      try desktop.drawFrame()
      #expect(window.commandIDs.contains(DesktopMenus.outputPrefix + "gone"))
      #expect(window.title(of: DesktopMenus.outputPrefix + "gone")?.hasSuffix("(Not Connected)") == true)
      #expect(window.isChecked?(DesktopMenus.outputPrefix + "gone") == true)
      desktop.session.outputDevice = nil
    }
  }

  /// Two microphones, one of them the system's.
  final class Microphones: AudioCapturing {
    var chosen: String?
    var devices = [AudioDevice(id: "{mic}", name: "Microphone"), AudioDevice(id: "{usb}", name: "Interface")]
    var current: AudioDevice?
    var systemDefault: AudioDevice? { devices.first }
    var error: String?
    var onChange: (() -> Void)?
    var destination: LiveInput?
  }

  /// Audio ▸ Input lists what the rack can listen to, where it can listen at all, ticks the choice,
  /// and names one chosen and not plugged in, as the outputs do.
  @Test func theAudioMenuChoosesTheRacksInput() throws {
    let device = try #require(try Self.devices().first)
    let window = StandInWindow()
    let microphones = Microphones()
    let desktop = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
      surface: StandInSurface(device: device, width: 320, height: 180), typesetter: NoTypesetter(),
      rack: RackSession(input: microphones))
    let rack = try #require(desktop.rack)
    try desktop.drawFrame()
    #expect(window.isChecked?(DesktopMenus.systemInput) == true)
    #expect(window.title(of: DesktopMenus.audioInputPrefix + "{usb}") == "Interface")
    window.choose(DesktopMenus.audioInputPrefix + "{usb}")
    #expect(rack.inputDevice == "{usb}" && microphones.chosen == "{usb}")
    #expect(window.isChecked?(DesktopMenus.audioInputPrefix + "{usb}") == true)
    #expect(window.isChecked?(DesktopMenus.systemInput) == false)

    microphones.devices.removeLast()
    microphones.onChange?()
    try desktop.drawFrame()
    #expect(window.title(of: DesktopMenus.audioInputPrefix + "{usb}") == "Interface (Not Connected)")
    window.choose(DesktopMenus.systemInput)
    #expect(rack.inputDevice == nil)

    let without = StandInWindow()
    let plain = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: without, device: device,
      surface: StandInSurface(device: device, width: 320, height: 180), typesetter: NoTypesetter(),
      rack: RackSession())
    try plain.drawFrame()
    #expect(without.commandIDs.contains(DesktopMenus.systemOutput))
    #expect(!without.commandIDs.contains(DesktopMenus.systemInput), "no input to choose where there is none")
  }

  /// A song dropped on the window opens, as Open would open it; anything else dropped is let be.
  @Test func aDroppedSongOpens() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, _) = try Self.desktop(on: device)
        let url = directory.appendingPathComponent("Groove.driftbox")
        try Data(SongCodec.encode(Self.song()).utf8).write(to: url)
        window.onEvent?(.dropped([directory.appendingPathComponent("Loop.wav")], at: SIMD2(40, 40)))
        try desktop.drawFrame()
        #expect(window.title == "Driftbox")
        window.onEvent?(.dropped([directory.appendingPathComponent("Loop.wav"), url], at: SIMD2(40, 40)))
        try desktop.drawFrame()
        #expect(window.title == "Groove - Driftbox")
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
  /// The song as audio, from the File menu: the mix as one WAV where it is asked to go, and each
  /// voice it uses as a WAV of its own in the folder chosen; nothing with no song, or no place.
  @Test func theSongIsExportedAsAudio() async throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    #expect(window.isEnabled?(DesktopMenus.exportMix) == false, "no song, nothing to export")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let song = directory.appendingPathComponent("Groove.driftbox")
    try Data(SongCodec.encode(Self.song()).utf8).write(to: song)
    window.chosenFile = song
    window.choose(DesktopMenus.open)
    #expect(
      window.commandIDs.contains(DesktopMenus.exportMix)
        && window.commandIDs.contains(DesktopMenus.exportStems))

    window.choose(DesktopMenus.exportMix)
    #expect(desktop.exporting == nil, "no place chosen")
    let mix = directory.appendingPathComponent("Groove.wav")
    window.saveLocation = mix
    window.choose(DesktopMenus.exportMix)
    await desktop.exporting?.value
    #expect(window.told == [], "the mix was written")
    let wav = try Data(contentsOf: mix)
    #expect(wav.prefix(4) == Data("RIFF".utf8) && wav.count > 44 + 48000)

    let stems = directory.appendingPathComponent("Stems")
    try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
    window.folder = stems
    window.choose(DesktopMenus.exportStems)
    await desktop.exporting?.value
    #expect(window.told == [], "the stems were written")
    #expect(try FileManager.default.contentsOfDirectory(atPath: stems.path) == ["Groove - 909.bd.wav"])
  }

  /// Told a screen reader's there only while one reads the window, and then what the groovebox shows;
  /// and what it asks, done.
  @Test func aScreenReaderIsToldWhatIsOnScreen() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Groove")
    try desktop.drawFrame()
    #expect(window.described.isEmpty, "nobody reading, nothing told")

    window.isDescribed = true
    try desktop.drawFrame()
    let told = try #require(window.described.last)
    #expect(told.node("transport.play")?.isOn == false)
    // A frame a moment later, told as of its own time rather than the clock's: a slow runner's next
    // frame can be later than the moment.
    desktop.describe(at: desktop.describedAt + Desktop.describing / 2)
    #expect(window.described.count == 1, "not every frame")

    window.onEvent?(.accessibility(.set("number.tempo", 100)))
    #expect(desktop.session.song?.bpm == 100)
    desktop.describedAt = -.infinity
    try desktop.drawFrame()
    #expect(window.described.last?.node("number.tempo")?.current == 100)
  }

  /// With the rack showing, the rack is what a screen reader is told, and what it asks of it is done
  /// there: a press that asks for a menu is shown the menu, as a click's is.
  @Test func aScreenReaderIsToldOfTheRack() throws {
    let device = try #require(try Self.devices().first)
    let window = StandInWindow()
    let surface = StandInSurface(device: device, width: 320, height: 180)
    let desktop = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device, surface: surface,
      typesetter: NoTypesetter(), rack: RackSession())
    let rack = try #require(desktop.rack)
    window.isDescribed = true
    window.choose(DesktopMenus.showRack)
    try desktop.drawFrame()
    let told = try #require(window.described.last)
    #expect(told.node("rack.run")?.isOn == false)
    #expect(told.node("transport.play") == nil, "not the groovebox")

    window.onEvent?(.accessibility(.press("rack.run")))
    #expect(rack.running)
    window.onEvent?(.accessibility(.press("rack.add")))
    #expect(window.popped.last?.title == "Add")
    #expect(!desktop.session.isPlaying, "the groovebox's own untouched")
  }

  /// With a screen reader running, Tab and Shift+Tab move the keyboard between the controls, which
  /// the screen reader is told at once; Enter presses the one it is on, and the arrows turn a
  /// slider. Without one, Tab is the shortcut it always was, and the keys are the instrument's.
  @Test func theKeyboardMovesBetweenTheControls() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Groove")
    window.isDescribed = true
    func press(_ key: Key, _ modifiers: Modifiers = []) {
      window.onEvent?(.key(KeyEvent(key: key, modifiers: modifiers)))
    }
    func tab() -> Shortcut? {
      window.menuBar?.commands.first { $0.id == DesktopMenus.controls }?.shortcut
    }

    press(.tab)
    #expect(window.focusedIds.compactMap { $0 }.isEmpty, "no screen reader, nowhere to move")
    #expect(tab() == Shortcut(.tab, []))

    window.screenReaderIsOn = true
    try desktop.drawFrame()
    #expect(tab() == nil, "Tab is the screen reader's now")
    press(.tab)
    let first = try #require(window.focusedIds.last ?? nil)
    let controls = desktop.described.flattened.filter { Desktop.focusable($0.role) }
    #expect(first == controls.first?.id, "the first control")
    press(.tab, .shift)
    #expect(window.focusedIds.last == controls.last?.id, "and back round to the last")
    press(.tab)
    #expect(window.focusedIds.last == first)

    // Pressed where it is: the metronome clicks, and stops.
    window.onEvent?(.accessibility(.focus("transport.metronome")))
    press(.return)
    #expect(desktop.session.metronome)
    press(.return)
    #expect(!desktop.session.metronome)

    // A screen reader moves it too, and the arrows turn what it is on.
    window.onEvent?(.accessibility(.focus("number.tempo")))
    #expect(window.focusedIds.last == "number.tempo")
    press(.up)
    #expect(desktop.session.song?.bpm == 121)
    press(.left)
    press(.left)
    #expect(desktop.session.song?.bpm == 119)
    try desktop.drawFrame()
    #expect(desktop.focusFrame != nil, "ringed")

    // Put away, there is nothing to be on; and Tab brings the controls back.
    desktop.interface.isShowing = false
    desktop.describeNow()
    #expect(window.focusedIds.last == .some(nil))
    press(.tab)
    #expect(desktop.interface.isShowing)
  }

  /// Help ▸ Groovebox Guide, on F1 while the groovebox shows: drawn over the window, told to a screen
  /// reader in the controls' place, and having the pointer and the keys until Esc puts it away. With
  /// the rack showing, F1 is the rack's guide.
  @Test func aGuideIsShownOverTheWindow() throws {
    let device = try #require(try Self.devices().first)
    let window = StandInWindow()
    let surface = StandInSurface(device: device, width: 320, height: 180)
    let desktop = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device, surface: surface,
      typesetter: NoTypesetter(), rack: RackSession())
    desktop.session.open(Self.song(), named: "Groove")
    func shortcut(_ id: String) -> Shortcut? { window.menuBar?.commands.first { $0.id == id }?.shortcut }
    #expect(shortcut(DesktopMenus.grooveboxGuide) == Shortcut(.function(1), []))
    #expect(shortcut(DesktopMenus.rackGuide) == nil)

    window.isDescribed = true
    window.choose(DesktopMenus.grooveboxGuide)
    try desktop.drawFrame()
    #expect(desktop.help?.guide.title == "Groovebox guide")
    #expect(window.described.last?.node("help") != nil)
    #expect(window.described.last?.node("transport.play") == nil, "the controls under it are not read")
    window.onEvent?(.pointer(PointerEvent(phase: .began, location: SIMD2(5, 170))))
    window.onEvent?(.pointer(PointerEvent(phase: .ended, location: SIMD2(5, 170))))
    #expect(desktop.session.padTouch == nil, "nor pressed")
    window.onEvent?(.key(KeyEvent(key: .character("a"))))
    window.onEvent?(.key(KeyEvent(key: .escape)))
    #expect(desktop.help == nil)
    #expect(window.described.last?.node("transport.play") != nil)

    window.choose(DesktopMenus.showRack)
    try desktop.drawFrame()
    #expect(shortcut(DesktopMenus.rackGuide) == Shortcut(.function(1), []))
    window.choose(DesktopMenus.rackGuide)
    #expect(desktop.help?.guide.title == "Rack guide")
    window.onEvent?(.accessibility(.press("help.close")))
    #expect(desktop.help == nil)
  }

  /// Transport ▸ Clear Loop: whatever is looping, one section or several stretched across, which
  /// Loop This Section would only replace; and nothing to clear while nothing loops.
  @Test func aLoopIsCleared() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Groove")
    #expect(window.isEnabled?(DesktopMenus.clearLoop) == false)
    desktop.session.toggleLoop(start: 0, bars: 1)
    desktop.session.extendLoop(toStart: 1, bars: 1)
    #expect(desktop.session.loop?.bars == 2)
    #expect(window.isEnabled?(DesktopMenus.clearLoop) == true)
    window.choose(DesktopMenus.clearLoop)
    #expect(desktop.session.loop == nil)
  }

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

  /// A groovebox song goes into the rack from the Rack menu, and is edited in the groovebox, linked,
  /// with the groovebox shown again; another patch in the rack lets it go.
  @Test func aRacksSongIsEditedInTheGroovebox() throws {
    for device in try Self.devices() {
      let window = StandInWindow()
      let desktop = try Desktop(
        session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
        surface: StandInSurface(device: device, width: 320, height: 180), typesetter: NoTypesetter(),
        rack: RackSession())
      let rack = try #require(desktop.rack)
      let entry = try #require(desktop.session.entries.first)
      #expect(window.commandIDs.contains(DesktopMenus.rackSongPrefix + entry.id))
      #expect(!window.commandIDs.contains(DesktopMenus.rackSongFromGroovebox), "no song in the groovebox")

      window.choose(DesktopMenus.rackSongPrefix + entry.id)
      #expect(rack.song != nil && rack.name == entry.name && desktop.showsRack)
      desktop.editRackSong()
      try desktop.drawFrame()
      #expect(rack.songLinked && desktop.session.linkedToRack && !desktop.showsRack)
      #expect(window.title == "\(entry.name) - Driftbox")
      #expect(!window.commandIDs.contains(DesktopMenus.rackSongFromGroovebox), "it is the rack's already")

      window.choose(DesktopMenus.patchPrefix + "acid")
      #expect(!desktop.session.linkedToRack && !rack.songLinked, "another patch lets the song go")
      try desktop.drawFrame()
      #expect(window.commandIDs.contains(DesktopMenus.rackSongFromGroovebox))
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

  /// A MIDI keyboard plays the rack while it shows, and the groovebox otherwise: the rack's notes,
  /// and a controller learnt by a param armed for it, reach it only in front. Its MIDI module knows
  /// the sources there are either way, to say it is listening.
  @Test func midiPlaysTheRackWhileItShows() throws {
    for device in try Self.devices() {
      let cables = Cables()
      let host = EngineHost(sampleRate: 48000)
      let window = StandInWindow()
      let desktop = try Desktop(
        session: Session(host: host, midiIn: cables), window: window, device: device,
        surface: StandInSurface(device: device, width: 320, height: 180), typesetter: NoTypesetter(),
        rack: RackSession())
      let rack = try #require(desktop.rack)
      #expect(rack.midiSources == ["Keys"])
      window.choose(DesktopMenus.songPrefix + "hothouse")
      desktop.session.stop()

      /// Whether `bytes`, from the cable, played the groovebox's 303.
      func playsTheGroovebox(_ bytes: [UInt8]) -> Bool {
        renderAudio(host, frames: 512)
        desktop.session.tick()
        _ = desktop.session.takeEvents()
        cables.send(bytes)
        renderAudio(host, frames: 512)
        desktop.session.tick()
        return desktop.session.takeEvents().contains { $0.kind == .note }
      }

      rack.startCcLearn("combi", "rotary1")
      #expect(playsTheGroovebox([0x90, 60, 100]), "the groovebox's while the rack is hidden")
      cables.send([0xB0, 74, 10])
      #expect(rack.lastNote == nil && rack.ccLearning != nil, "and not the rack's")

      window.choose(DesktopMenus.showRack)
      #expect(!playsTheGroovebox([0x90, 62, 100]), "the rack's while it shows")
      #expect(rack.lastNote == 62)
      cables.send([0xB0, 74, 10])
      #expect(rack.ccBindings == [RackCC.Binding(cc: 74, module: "combi", param: "rotary1")])

      cables.sources = ["Keys", "Elektron"]
      cables.onSourcesChange?(cables.sources)
      #expect(rack.midiSources == ["Keys", "Elektron"])

      window.choose(DesktopMenus.showRack)
      #expect(playsTheGroovebox([0x90, 64, 100]), "the groovebox's again once it is hidden")
      #expect(rack.lastNote == 62)
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

/// A MIDI input with one keyboard plugged in, played by the test: each message goes where a real
/// port's would, a note to `onNote` as well.
final class Cables: MIDIInputPort, @unchecked Sendable {
  var onNote: (@Sendable (Int, Double) -> Void)?
  var onMessage: (@Sendable ([UInt8]) -> Void)?
  var onClock: (@Sendable (ClockMessage, Double) -> Void)?
  var onSourcesChange: (@Sendable ([String]) -> Void)?
  var sources = ["Keys"]
  var ignoring: Set<String> = []

  func send(_ bytes: [UInt8]) {
    if let status = bytes.first, bytes.count == 3,
      case .note(let note, let velocity) = MIDIMessage(status: status, bytes[1], bytes[2])
    {
      onNote?(note, velocity)
    }
    onMessage?(bytes)
  }
}

/// Run the engine for `frames`, in the blocks an audio device would ask for.
func renderAudio(_ host: EngineHost, frames: Int) {
  var left = [Float](repeating: 0, count: 512)
  var right = [Float](repeating: 0, count: 512)
  var done = 0
  while done < frames {
    let count = min(512, frames - done)
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        host.render(frames: count, left: l.baseAddress!, right: r.baseAddress!)
      }
    }
    done += count
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

extension DesktopTests {
  @Test func deferredCloseWaitsForSaveAndDoesNotLoseChangesOnFailure() throws {
    for device in try Self.devices() {
      try withTemporaryDirectory { directory in
        let (desktop, window, surface) = try Self.desktop(on: device)
        window.choose(DesktopMenus.new)
        desktop.session.edit("Tempo") { $0.bpm = 135 }
        window.defersDialogs = true
        #expect(window.shouldClose?() == false)
        #expect(window.shouldClose?() == false)
        #expect(window.asked.count == 1)
        window.choose(DesktopMenus.new)
        #expect(desktop.session.song?.bpm == 135)
        try desktop.drawFrame()
        #expect(surface.presented == 1, "drawing continues while a native dialog is pending")
        let question = try #require(window.pendingQuestion)
        window.pendingQuestion = nil
        question(.save)
        let save = try #require(window.pendingSave)
        window.pendingSave = nil
        save(directory.appendingPathComponent("missing/failure.driftbox"))
        #expect(desktop.session.isEdited)
        #expect(!window.closed)
        #expect(!desktop.documentRequestPending)
        #expect(window.shouldClose?() == false)
        let again = try #require(window.pendingQuestion)
        window.pendingQuestion = nil
        again(.save)
        let successful = try #require(window.pendingSave)
        window.pendingSave = nil
        let path = directory.appendingPathComponent("Saved.driftbox")
        successful(path)
        #expect(window.closed)
        #expect(!desktop.session.isEdited)
        let saved = SongCodec.decode(String(decoding: try Data(contentsOf: path), as: UTF8.self))
        #expect(saved?.bpm == 135)
      }
    }
  }

  @Test func aPendingDialogStillReleasesThePerformancePad() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      window.choose(DesktopMenus.new)
      desktop.interface.isShowing = false
      window.onEvent?(.pointer(PointerEvent(phase: .began, location: SIMD2(80, 135))))
      #expect(desktop.session.padTouch != nil)
      window.defersDialogs = true
      window.choose(DesktopMenus.saveAs)
      #expect(desktop.documentRequestPending)
      window.onEvent?(.pointer(PointerEvent(phase: .cancelled, location: .zero)))
      #expect(desktop.session.padTouch == nil)
      window.onEvent?(.pointer(PointerEvent(phase: .began, location: SIMD2(80, 135))))
      #expect(desktop.session.padTouch == nil, "new gestures wait for the modal dialog")
      let cancel = try #require(window.pendingSave)
      window.pendingSave = nil
      cancel(nil)
      #expect(!desktop.documentRequestPending)
    }
  }

  @Test func deferredOpenAndCloseCancellationLeaveTheCurrentSongAlone() throws {
    for device in try Self.devices() {
      let (desktop, window, _) = try Self.desktop(on: device)
      window.choose(DesktopMenus.new)
      desktop.session.edit("Tempo") { $0.bpm = 137 }
      window.defersDialogs = true
      window.choose(DesktopMenus.open)
      #expect(desktop.documentRequestPending)
      let question = try #require(window.pendingQuestion)
      window.pendingQuestion = nil
      question(.discard)
      let open = try #require(window.pendingOpen)
      window.pendingOpen = nil
      open(nil)
      #expect(desktop.session.song?.bpm == 137)
      #expect(desktop.session.isEdited)
      #expect(!desktop.documentRequestPending)
      #expect(window.shouldClose?() == false)
      let closing = try #require(window.pendingQuestion)
      window.pendingQuestion = nil
      closing(.cancel)
      #expect(!window.closed)
      #expect(!desktop.documentRequestPending)
    }
  }
}

extension DesktopTests {
  @Test func rackAudioMenuTargetsModulesAndCancelsWithoutChangingThePatch() throws {
    for device in try Self.devices() {
      let window = StandInWindow()
      let rack = RackSession()
      let desktop = try Desktop(
        session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
        surface: StandInSurface(device: device, width: 320, height: 180),
        typesetter: NoTypesetter(), rack: rack)
      let sampler = try #require(rack.add("sampler"))
      let second = try #require(rack.add("sampler"))
      let instrument = try #require(rack.add("multisampler"))
      let track = try #require(rack.add("audio-track"))
      let oscillator = try #require(rack.add("vco"))
      try desktop.drawFrame()
      let command = DesktopMenus.rackAudioPrefix
      #expect(window.title(of: command + sampler) == "Sampler 1…")
      #expect(window.title(of: command + second) == "Sampler 2…")
      #expect(window.commandIDs.contains(command + instrument))
      #expect(window.commandIDs.contains(command + track))
      #expect(!window.commandIDs.contains(command + oscillator))
      #expect(window.isEnabled?(command + oscillator) == false)
      #expect(window.isEnabled?(command + "missing") == false)
      let before = rack.patch
      window.defersDialogs = true
      for module in [sampler, track] {
        window.choose(command + module)
        #expect(desktop.showsRack && desktop.documentRequestPending)
        #expect(window.requestedTypes.first?.extensions == ["wav", "wave"])
        #expect(window.isEnabled?(command + instrument) == false)
        let cancel = try #require(window.pendingOpen)
        window.pendingOpen = nil
        cancel(nil)
        #expect(!desktop.documentRequestPending)
        #expect(rack.patch == before)
      }
      window.choose(command + instrument)
      #expect(window.pendingOpen == nil, "an instrument must allow several files")
      let cancel = try #require(window.pendingMultiple)
      window.pendingMultiple = nil
      cancel([])
      #expect(!desktop.documentRequestPending)
      #expect(rack.patch == before)
      window.choose(DesktopMenus.patchPrefix + "acid")
      try desktop.drawFrame()
      #expect(!window.commandIDs.contains(command + sampler), "targets follow the current patch")
      #expect(window.isEnabled?(command + sampler) == false)
    }
  }
}

extension DesktopTests {
  @Test func exportsWaitForDeferredLocations() async throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Deferred")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    window.defersDialogs = true
    for command in [DesktopMenus.exportMix, DesktopMenus.exportStems, DesktopMenus.exportMovie] {
      window.choose(command)
      #expect(desktop.documentRequestPending)
      #expect(window.isEnabled?(DesktopMenus.new) == false)
      #expect(desktop.exporting == nil && desktop.movie == nil)
      let cancel = try #require(
        command == DesktopMenus.exportStems ? window.pendingFolder : window.pendingSave)
      window.pendingFolder = nil
      window.pendingSave = nil
      cancel(nil)
      #expect(!desktop.documentRequestPending)
      #expect(desktop.exporting == nil && desktop.movie == nil)
    }
    window.choose(DesktopMenus.exportMix)
    let mix = directory.appendingPathComponent("Mix.wav")
    let saveMix = try #require(window.pendingSave)
    saveMix(mix)
    window.pendingSave = nil
    #expect(!desktop.documentRequestPending)
    await desktop.exporting?.value
    #expect(try Data(contentsOf: mix).prefix(4) == Data("RIFF".utf8))
    window.choose(DesktopMenus.exportStems)
    let saveStems = try #require(window.pendingFolder)
    saveStems(directory)
    window.pendingFolder = nil
    await desktop.exporting?.value
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.contains { $0.hasPrefix("Deferred - ") && $0.hasSuffix(".wav") })
    desktop.supportsMovies = false
    #expect(window.isEnabled?(DesktopMenus.exportMovie) == false)
    #expect(window.isEnabled?(DesktopMenus.record) == false)
  }
}

extension DesktopTests {
  @Test func documentFailuresAreReportedOnceAndCanRecur() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Kept")
    let before = desktop.session.song
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    window.chosenFile = missing
    window.choose(DesktopMenus.open)
    desktop.refresh()
    #expect(desktop.session.song == before)
    #expect(window.told.count == 1 && window.told[0].contains(missing.lastPathComponent))
    #expect(desktop.session.error == nil)
    desktop.refresh()
    #expect(window.told.count == 1)
    window.choose(DesktopMenus.open)
    desktop.refresh()
    #expect(window.told.count == 2, "the same failure on a new attempt is reported again")
  }

  @Test func failedSaveAsIsNotSuccessForAnUneditedSong() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Kept")
    #expect(!desktop.session.isEdited)
    window.saveLocation = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("Missing/Save.driftbox")
    var saved: Bool?
    desktop.saveAs { saved = $0 }
    #expect(saved == false)
    #expect(desktop.session.fileURL == nil && desktop.session.documentName == "Kept")
    desktop.refresh()
    #expect(window.told.count == 1)
    #expect(window.told.first?.hasPrefix("Could not save Save.driftbox:") == true)
  }

  @Test func failedSaveBeforeClosingKeepsEditsAndReportsAfterTheDialog() throws {
    let device = try #require(try Self.devices().first)
    let (desktop, window, _) = try Self.desktop(on: device)
    desktop.session.open(Self.song(), named: "Kept")
    desktop.session.edit("Tempo") { $0.bpm = 137 }
    window.defersDialogs = true
    #expect(window.shouldClose?() == false)
    let question = try #require(window.pendingQuestion)
    window.pendingQuestion = nil
    question(.save)
    desktop.refresh()
    #expect(window.told.isEmpty && desktop.documentRequestPending)
    let save = try #require(window.pendingSave)
    window.pendingSave = nil
    save(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("Missing/Save.driftbox"))
    #expect(!window.closed && !desktop.documentRequestPending)
    #expect(desktop.session.isEdited && desktop.session.song?.bpm == 137)
    desktop.refresh()
    #expect(window.told.count == 1)
    desktop.refresh()
    #expect(window.told.count == 1)
  }
}
