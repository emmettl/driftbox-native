import DriftboxDocument
import DriftboxGPU
import DriftboxHost
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation
import Testing

@testable import DriftboxDesktop

/// The visuals in a window of their own, from the View menu: sent to a display and full screen
/// there, drawn every frame with the backdrop showing the same frame, and put back at the next
/// launch; closed by a person, it stays closed.
@MainActor
struct DesktopVisualsTests {
  /// A desktop whose platform has a visuals window and two displays, with the test song open, and
  /// the surfaces the visuals window was given.
  static func desktop(memory: UserDefaults? = nil) throws -> (Desktop, StandInWindow, Surfaces) {
    let device = try #require(try DesktopTests.devices().first)
    let window = StandInWindow()
    window.displays = ["Main", "Projector"]
    let surfaces = Surfaces()
    let desktop = try Desktop(
      session: Session(host: EngineHost(sampleRate: 48000)), window: window, device: device,
      surface: StandInSurface(device: device, width: 320, height: 180), typesetter: NoTypesetter(),
      visualsSurface: { visuals in
        let made = StandInSurface(device: device, width: visuals.width, height: visuals.height)
        surfaces.made.append(made)
        return made
      })
    desktop.memory = memory
    desktop.session.open(DesktopTests.song(), named: "Groove")
    return (desktop, window, surfaces)
  }

  final class Surfaces {
    var made: [StandInSurface] = []
  }

  static func memory() throws -> (UserDefaults, String) {
    let suite = "driftbox-visuals-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// With no second window on the platform, the View menu offers none.
  @Test func withNoSecondWindowThereIsNone() throws {
    let device = try #require(try DesktopTests.devices().first)
    let (_, window, _) = try DesktopTests.desktop(on: device)
    #expect(!window.commandIDs.contains(DesktopMenus.visualsWindow))
  }

  /// Opened from the View menu, the window draws the scene each frame at its own size; sent full
  /// screen to a display by name, it is ticked there; Space in it plays and stops; and a new size is
  /// drawn at from the next frame.
  @Test func theVisualsHaveAWindowOfTheirOwn() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let (desktop, window, surfaces) = try Self.desktop(memory: memory)
    #expect(window.commandIDs.contains(DesktopMenus.visualsWindow))
    #expect(
      window.commandIDs.filter { $0.hasPrefix(DesktopMenus.visualsOnPrefix) }
        == ["visualsOn.Main", "visualsOn.Projector"])

    window.choose(DesktopMenus.visualsWindow)
    #expect(desktop.visualsOpen && window.isChecked?(DesktopMenus.visualsWindow) == true)
    let surface = try #require(surfaces.made.first)
    try desktop.drawFrame()
    try desktop.drawFrame()
    #expect(surface.presented == 2, "drawn every frame")

    window.choose(DesktopMenus.visualsOnPrefix + "Projector")
    let visuals = try #require(window.visualsWindows.last)
    #expect(visuals.display == "Projector" && visuals.isFullScreen)
    #expect(window.isChecked?(DesktopMenus.visualsOnPrefix + "Projector") == true)
    #expect(window.isChecked?(DesktopMenus.visualsOnPrefix + "Main") == false)
    #expect(
      memory.bool(forKey: "visuals.window.open")
        && memory.string(forKey: "visuals.window.screen") == "Projector")
    #expect(memory.bool(forKey: "visuals.window.fullScreen"))
    #expect(window.visualsWindows.count == 1, "the same window, sent on")

    visuals.onEvent?(.key(KeyEvent(key: .space, modifiers: [], isDown: true, isRepeat: false)))
    // Playing once the engine has played a moment and the session has heard.
    DesktopMovieTests.play(desktop, seconds: 0.05)
    #expect(desktop.session.isPlaying)
    visuals.onEvent?(.resized(width: 1920, height: 1080, scale: 1))
    try desktop.drawFrame()
    #expect(surface.width == 1920 && surface.height == 1080)
  }

  /// Closed by a person, it is gone and stays closed at the next launch; closed from the View menu,
  /// likewise. Left open when the app quits, it comes back where it was.
  @Test func theWindowIsRememberedAsItWasLeft() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let (desktop, window, _) = try Self.desktop(memory: memory)
    desktop.showVisuals(on: "Projector", fullScreen: true)
    try desktop.run()
    #expect(window.visualsWindows.last?.closed == true, "closed with the app")
    #expect(memory.bool(forKey: "visuals.window.open"), "and remembered as open")

    let (again, reopened, _) = try Self.desktop(memory: memory)
    again.restoreVisuals()
    let restored = try #require(reopened.visualsWindows.last)
    #expect(again.visualsOpen && restored.display == "Projector" && restored.isFullScreen)

    restored.onEvent?(.closed)
    #expect(!again.visualsOpen && !memory.bool(forKey: "visuals.window.open"))
    try again.drawFrame()

    reopened.choose(DesktopMenus.visualsWindow)
    #expect(again.visualsOpen && memory.bool(forKey: "visuals.window.open"))
    reopened.choose(DesktopMenus.visualsWindow)
    #expect(!again.visualsOpen && !memory.bool(forKey: "visuals.window.open"))
    #expect(reopened.visualsWindows.last?.closed == true)

    let (third, fresh, _) = try Self.desktop(memory: memory)
    third.restoreVisuals()
    #expect(!third.visualsOpen && fresh.visualsWindows.isEmpty, "closed, so not put back")
  }
}
