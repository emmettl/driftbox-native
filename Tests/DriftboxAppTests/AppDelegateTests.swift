#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxDocument
  import DriftboxHost
  import DriftboxSeq
  import DriftboxSession
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// What only an application object hears: songs from the Finder, and a quit.
  @MainActor
  struct AppDelegateTests {
    @Test func aFileArrivingBeforeTheWindowWaitsForIt() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), named: "Waiting", in: directory)
        let second = directory.appendingPathComponent("Second.song.json")
        try Data(SongCodec.encode(steadySong(bpm: 96)).utf8).write(to: second)

        // Opening a song in the Finder starts the app, so the file can arrive before there is
        // anything to open it into.
        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [second])
        #expect(player.documentName == "Waiting")

        delegate.attach(SongFiles(player: player))
        #expect(player.documentName == "Second")
        #expect(player.song?.bpm == 96)
      }
    }

    /// One window, one song: the last file asked for is the one that gets opened, and a second
    /// window would only be the same player twice.
    @Test func theLastFileAskedForIsTheOneThatOpens() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), named: "First", in: directory)
        let second = directory.appendingPathComponent("Second.song.json")
        try Data(SongCodec.encode(steadySong(bpm: 96)).utf8).write(to: second)
        let third = directory.appendingPathComponent("Third.song.json")
        try Data(SongCodec.encode(steadySong(bpm: 144)).utf8).write(to: third)

        let delegate = AppDelegate()
        delegate.attach(SongFiles(player: player))
        // Attaching again would hand the same window to a second set of files.
        delegate.attach(SongFiles(player: Session(host: EngineHost(sampleRate: 48000))))

        delegate.application(NSApplication.shared, open: [second, third])
        #expect(player.documentName == "Third")
        #expect(player.song?.bpm == 144)
      }
    }

    @Test func quittingOverNothingUnsavedIsAllowed() {
      let delegate = AppDelegate()
      #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
      #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

      let player = Session(host: EngineHost(sampleRate: 48000))
      delegate.attach(SongFiles(player: player))
      player.new()
      #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    /// The File menu's own doors, with nothing unsaved for any of them to ask about.
    @Test func theFileMenuOpensWhatItIsGiven() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), named: "Opened", in: directory)
        let files = SongFiles(player: player)
        #expect(files.confirmDiscard())

        files.new()
        #expect(player.documentName == "Untitled")

        let entry = try #require(player.entries.first)
        files.open(entry)
        #expect(player.documentName == entry.name)

        files.open(directory.appendingPathComponent("Opened.song.json"))
        #expect(player.documentName == "Opened")
        // The recents list belongs to the document controller, which keeps its own counsel outside
        // an application bundle; what is asked of it here is only that it answers.
        let recent = files.recent
        #expect(recent.allSatisfy { $0.isFileURL })
      }
    }
  }
#endif
