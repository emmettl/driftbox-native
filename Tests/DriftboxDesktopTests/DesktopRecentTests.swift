import DriftboxDocument
import DriftboxGPU
import DriftboxHost
import DriftboxSession
import DriftboxShell
import DriftboxText
import Foundation
import Testing

@testable import DriftboxDesktop

/// File ▸ Open Recent: the songs opened and saved lately, the latest first, each told to the
/// platform's own list too; opened from the menu, and one gone taken off it.
@MainActor
struct DesktopRecentTests {
  static func desktop(memory: UserDefaults?) throws -> (Desktop, StandInWindow) {
    let device = try #require(try DesktopTests.devices().first)
    let (desktop, window, _) = try DesktopTests.desktop(on: device)
    desktop.memory = memory
    desktop.refresh()
    return (desktop, window)
  }

  static func memory() throws -> (UserDefaults, String) {
    let suite = "driftbox-recent-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// A song written to `name` in `folder`.
  static func song(_ name: String, in folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(SongCodec.encode(DesktopTests.song()).utf8).write(to: url)
    return url
  }

  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "driftbox-recent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The recent songs' menu titles, in order.
  static func titles(_ window: StandInWindow) -> [String] {
    window.menuBar?.commands.filter { $0.id.hasPrefix(DesktopMenus.recentPrefix) }.map(\.title) ?? []
  }

  /// Opened and saved as, each goes first, once; the platform is told of each; and the list keeps ten.
  @Test func theSongsOpenedAndSavedAreListed() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let folder = try Self.directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (desktop, window) = try Self.desktop(memory: memory)
    #expect(
      window.commandIDs.contains(DesktopMenus.noRecent) && window.isEnabled?(DesktopMenus.noRecent) == false)

    let first = try Self.song("Rock & Roll.driftbox", in: folder)
    window.chosenFile = first
    window.choose(DesktopMenus.open)
    desktop.refresh()
    #expect(Self.titles(window) == ["Rock & Roll.driftbox"])
    #expect(window.recents.map(\.lastPathComponent) == ["Rock & Roll.driftbox"])

    let second = folder.appendingPathComponent("Second.driftbox")
    window.saveLocation = second
    window.choose(DesktopMenus.saveAs)
    desktop.refresh()
    #expect(Self.titles(window) == ["Second.driftbox", "Rock & Roll.driftbox"])

    window.chosenFile = first
    window.choose(DesktopMenus.open)
    desktop.refresh()
    #expect(Self.titles(window) == ["Rock & Roll.driftbox", "Second.driftbox"], "moved to the top, once")

    for index in 0..<12 {
      window.chosenFile = try Self.song("Song \(index).driftbox", in: folder)
      window.choose(DesktopMenus.open)
      desktop.refresh()
    }
    #expect(Self.titles(window).count == 10 && Self.titles(window).first == "Song 11.driftbox")
  }

  /// Opened from the menu; one that has gone is taken off, and the person told; two that share a
  /// name are told apart by their folders; and the list is cleared from the menu.
  @Test func aRecentSongIsOpened() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let folder = try Self.directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (desktop, window) = try Self.desktop(memory: memory)
    let kept = try Self.song("Groove.driftbox", in: folder.appendingPathComponent("Kept"))
    let gone = try Self.song("Groove.driftbox", in: folder.appendingPathComponent("Gone"))
    for url in [kept, gone] {
      window.chosenFile = url
      window.choose(DesktopMenus.open)
      desktop.refresh()
    }
    #expect(Self.titles(window) == ["Groove.driftbox — Gone", "Groove.driftbox — Kept"])

    window.choose(DesktopMenus.new)
    desktop.refresh()
    window.choose(DesktopMenus.recentPrefix + "1")
    #expect(desktop.session.fileURL?.standardizedFileURL == kept.standardizedFileURL)
    desktop.refresh()
    #expect(Self.titles(window) == ["Groove.driftbox — Kept", "Groove.driftbox — Gone"], "opened, so first")

    try FileManager.default.removeItem(at: gone)
    window.choose(DesktopMenus.new)
    window.choose(DesktopMenus.recentPrefix + "1")
    #expect(window.told.count == 1 && window.told.first?.contains("not there any more") == true)
    desktop.refresh()
    #expect(Self.titles(window) == ["Groove.driftbox"], "taken off, and the other no longer needs its folder")

    window.choose(DesktopMenus.clearRecent)
    desktop.refresh()
    #expect(Self.titles(window).isEmpty && window.commandIDs.contains(DesktopMenus.noRecent))
  }

  /// A song handed over before there is anywhere to keep the list is kept once there is; with
  /// nowhere at all, there is no list.
  @Test func aSongHandedOverAtLaunchIsKept() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let folder = try Self.directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (desktop, window) = try Self.desktop(memory: nil)
    desktop.session.open(file: try Self.song("Launch.driftbox", in: folder))
    desktop.refresh()
    #expect(!window.commandIDs.contains(DesktopMenus.noRecent), "no memory, no list")
    desktop.memory = memory
    desktop.refresh()
    #expect(Self.titles(window) == ["Launch.driftbox"])
  }
}

extension DesktopRecentTests {
  @Test func recentOpenWaitsForTheUnsavedQuestion() throws {
    let (memory, suite) = try Self.memory()
    defer { memory.removePersistentDomain(forName: suite) }
    let folder = try Self.directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (desktop, window) = try Self.desktop(memory: memory)
    let url = try Self.song("Recent.driftbox", in: folder)
    desktop.noteRecent(url)
    desktop.session.open(DesktopTests.song(), named: "Edited")
    desktop.session.edit("Tempo") { $0.bpm = 99 }
    desktop.refresh()
    window.defersDialogs = true
    window.choose(DesktopMenus.recentPrefix + "0")
    #expect(desktop.documentRequestPending && desktop.session.isEdited)
    let cancel = try #require(window.pendingQuestion)
    cancel(.cancel)
    window.pendingQuestion = nil
    #expect(!desktop.documentRequestPending && desktop.session.isEdited)
    window.choose(DesktopMenus.recentPrefix + "0")
    let discard = try #require(window.pendingQuestion)
    discard(.discard)
    window.pendingQuestion = nil
    #expect(!desktop.documentRequestPending)
    #expect(desktop.session.fileURL == url)
  }

  #if os(Linux)
    @Test func linuxRecentPathsKeepCaseDistinct() throws {
      let (memory, suite) = try Self.memory()
      defer { memory.removePersistentDomain(forName: suite) }
      let (desktop, _) = try Self.desktop(memory: memory)
      desktop.noteRecent(URL(fileURLWithPath: "/tmp/Groove.driftbox"))
      desktop.noteRecent(URL(fileURLWithPath: "/tmp/groove.driftbox"))
      #expect(desktop.recentFiles.count == 2)
    }
  #endif
}
