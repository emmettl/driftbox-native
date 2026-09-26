import DriftboxDocument
import DriftboxGPU
import DriftboxHost
import DriftboxMovie
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Foundation
import Testing

@testable import DriftboxDesktop

/// Movies from the File menu, as the Mac's makes them: the song from the top, or a performance
/// recorded as it was played, written while the app carries on and then shown where they were put;
/// stopped part way, or failing, nothing left behind.
@MainActor
struct DesktopMovieTests {
  static let small = MovieFormat(
    width: 320, height: 180, framesPerSecond: 30, sampleRate: 48000, tailSeconds: 0.5)

  /// A desktop on the first device there is, with the test song open and movies written small.
  static func opened(in directory: URL) throws -> (Desktop, StandInWindow) {
    let device = try #require(try DesktopTests.devices().first)
    let (desktop, window, _) = try DesktopTests.desktop(on: device)
    let song = directory.appendingPathComponent("Groove.driftbox")
    try Data(SongCodec.encode(DesktopTests.song()).utf8).write(to: song)
    window.chosenFile = song
    window.choose(DesktopMenus.open)
    desktop.movieFormat = Self.small
    return (desktop, window)
  }

  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "driftbox-movies-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Until the movie being written is done.
  static func finished(_ desktop: Desktop) async {
    await desktop.movie?.value
  }

  /// The engine rendered as a device would, and the session told, as the app ticks it.
  static func play(_ desktop: Desktop, seconds: Double) {
    let frames = Int(seconds * 48000)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
      left.deallocate()
      right.deallocate()
    }
    desktop.session.host.render(frames: frames, left: left, right: right)
    desktop.session.tick()
  }

  #if os(Windows)
    /// Asked where, written while the title says how far, then shown in Explorer: the song's two
    /// passes of two seconds and its tail.
    @Test func theSongIsWrittenAsAMovie() async throws {
      let directory = try Self.directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let (desktop, window) = try Self.opened(in: directory)
      #expect(window.title(of: DesktopMenus.exportMovie) == "Export Movie…")
      let url = directory.appendingPathComponent("Groove.mp4")
      window.saveLocation = url
      window.choose(DesktopMenus.exportMovie)
      desktop.refresh()
      #expect(window.title.hasPrefix("Writing Movie"))
      #expect(window.commandIDs.contains(DesktopMenus.stopMovie))
      #expect(window.isEnabled?(DesktopMenus.record) == false, "one thing at a time")
      await Self.finished(desktop)
      desktop.refresh()
      #expect(window.revealed == [url] && window.told.isEmpty)
      #expect(window.title == "Groove - Driftbox")
      let read = try MovieContents.read(url)
      #expect(abs(read.seconds - 4.5) < 0.15, "\(read.seconds) seconds")
      #expect(read.width == 320 && read.height == 180)
    }

    /// A performance: recorded from the File menu while the title counts it, the scene switched part
    /// way, and written as long as it was played; stopped without a place, it is thrown away.
    @Test func aPerformanceIsRecordedAndWritten() async throws {
      let directory = try Self.directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let (desktop, window) = try Self.opened(in: directory)
      desktop.session.play()
      Self.play(desktop, seconds: 0.1)
      window.choose(DesktopMenus.record)
      #expect(desktop.session.isRecording)
      desktop.refresh()
      #expect(window.title.hasPrefix("Recording 0:00"))
      #expect(window.title(of: DesktopMenus.record) == "Stop Recording…")
      Self.play(desktop, seconds: 1)
      window.choose(DesktopMenus.scenePrefix + "pulse")
      Self.play(desktop, seconds: 1)

      let url = directory.appendingPathComponent("Performance.mp4")
      window.saveLocation = url
      window.choose(DesktopMenus.record)
      #expect(!desktop.session.isRecording)
      await Self.finished(desktop)
      #expect(window.revealed == [url])
      let read = try MovieContents.read(url)
      #expect(abs(read.seconds - 2) < 0.15, "\(read.seconds) seconds, as long as it was played")

      window.choose(DesktopMenus.record)
      Self.play(desktop, seconds: 0.5)
      window.saveLocation = nil
      window.choose(DesktopMenus.record)
      #expect(!desktop.session.isRecording && desktop.movieProgress == nil, "no place: thrown away")
    }

    /// Stopped part way from the File menu, nothing is left, shown or said.
    @Test func aMovieStoppedPartWayLeavesNothing() async throws {
      let directory = try Self.directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let (desktop, window) = try Self.opened(in: directory)
      let url = directory.appendingPathComponent("Stopped.mp4")
      window.saveLocation = url
      window.choose(DesktopMenus.exportMovie)
      desktop.refresh()
      window.choose(DesktopMenus.stopMovie)
      await Self.finished(desktop)
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(window.revealed.isEmpty && window.told.isEmpty && desktop.movieProgress == nil)
    }
  #endif

  /// A movie that cannot be written says why, in the window's own box.
  @Test func aMovieThatFailsSaysWhy() async throws {
    let directory = try Self.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (desktop, window) = try Self.opened(in: directory)
    desktop.makeMovieWriter = { _, _ in throw MovieFailure.writer("no room") }
    window.saveLocation = directory.appendingPathComponent("Nowhere.mp4")
    window.choose(DesktopMenus.exportMovie)
    await Self.finished(desktop)
    #expect(window.told.count == 1 && window.told.first?.contains("no room") == true)
    #expect(window.revealed.isEmpty && desktop.movieProgress == nil)
  }
}
