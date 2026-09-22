#if canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The song that was open when the app last quit, put back at the next launch. Each test keeps
  /// its memory in a preferences domain of its own and removes it afterwards, so nothing here is
  /// written where the application would read it.
  @MainActor
  struct RestoreTests {
    func withMemory<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
      let name = "driftbox-restore-\(UUID().uuidString)"
      let memory = UserDefaults(suiteName: name)!
      defer { memory.removePersistentDomain(forName: name) }
      return try body(memory)
    }

    func player(remembering memory: UserDefaults) -> (Player, EngineHost) {
      let host = EngineHost(sampleRate: 48000)
      let player = Player(host: host)
      player.memory = memory
      return (player, host)
    }

    @Test func aCatalogueSongComesBackStopped() throws {
      try withMemory { memory in
        let (first, _) = player(remembering: memory)
        let entry = try #require(first.entries.first)
        first.open(entry)

        let (next, host) = player(remembering: memory)
        next.restore()
        #expect(next.current?.id == entry.id)
        #expect(next.song != nil)
        // Sound nobody asked for is the one thing not worth restoring.
        renderAudio(host, frames: 4800)
        next.tick()
        #expect(!next.isPlaying)
        #expect(!next.isEdited)
      }
    }

    /// Through a bookmark, so a document renamed in the Finder since is still found.
    @Test func aDocumentComesBackEvenAfterBeingRenamed() throws {
      try withMemory { memory in
        try withTemporaryDirectory { directory in
          let url = directory.appendingPathComponent("Before.song.json")
          try Data(SongCodec.encode(steadySong(bpm: 131)).utf8).write(to: url)
          let (first, _) = player(remembering: memory)
          first.open(file: url)

          let renamed = directory.appendingPathComponent("After.song.json")
          try FileManager.default.moveItem(at: url, to: renamed)

          let (next, _) = player(remembering: memory)
          next.restore()
          #expect(next.song?.bpm == 131)
          #expect(next.fileURL?.lastPathComponent == "After.song.json")
          #expect(next.documentName == "After")
        }
      }
    }

    /// Gone is forgotten rather than reported: there is nothing anyone can do about a file that
    /// was deleted between two launches, and an error about it at startup is just noise.
    @Test func aDocumentThatHasGoneIsForgotten() throws {
      try withMemory { memory in
        try withTemporaryDirectory { directory in
          let url = directory.appendingPathComponent("Gone.song.json")
          try Data(SongCodec.encode(steadySong()).utf8).write(to: url)
          let (first, _) = player(remembering: memory)
          first.open(file: url)
          try FileManager.default.removeItem(at: url)

          let (next, _) = player(remembering: memory)
          next.restore()
          #expect(next.song == nil)
          #expect(next.error == nil)
          #expect(memory.data(forKey: Defaults.lastFile) == nil)
        }
      }
    }

    /// Saving somewhere new moves the memory with it.
    @Test func savingAsSomewhereElseIsWhatComesBack() throws {
      try withMemory { memory in
        try withTemporaryDirectory { directory in
          let (first, _) = player(remembering: memory)
          let entry = try #require(first.entries.first)
          first.open(entry)
          let copy = directory.appendingPathComponent("My Copy.song.json")
          first.save(to: copy)

          let (next, _) = player(remembering: memory)
          next.restore()
          #expect(next.fileURL?.lastPathComponent == "My Copy.song.json")
          #expect(memory.string(forKey: Defaults.lastSong) == nil)
        }
      }
    }

    /// A new song has nowhere to come back from, and quitting has already asked whether to
    /// save it.
    @Test func aNewSongLeavesNothingToRestore() throws {
      try withMemory { memory in
        let (first, _) = player(remembering: memory)
        let entry = try #require(first.entries.first)
        first.open(entry)
        first.new()

        let (next, _) = player(remembering: memory)
        next.restore()
        #expect(next.song == nil)
      }
    }

    /// A player built without a device keeps no memory, which is what lets every other test
    /// open files without rewriting what the application opens next.
    @Test func aPlayerWithoutADeviceRemembersNothing() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        #expect(player.memory == nil)
        player.restore()
      }
    }
  }
#endif
