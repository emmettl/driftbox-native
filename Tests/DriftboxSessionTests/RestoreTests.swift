import DriftboxDocument
import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

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

  func session(remembering memory: UserDefaults) -> (Session, EngineHost) {
    let host = EngineHost(sampleRate: 48000)
    let session = Session(host: host, memory: memory)
    return (session, host)
  }

  @Test func aCatalogueSongComesBackStopped() throws {
    try withMemory { memory in
      let (first, _) = session(remembering: memory)
      let entry = try #require(first.entries.first)
      first.open(entry)

      let (next, host) = session(remembering: memory)
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

  /// The pattern being worked on comes back with its song; one that follows the transport stays
  /// following, and opening a different song forgets the choice.
  @Test func thePatternBeingEditedComesBackWithItsSong() throws {
    try withMemory { memory in
      let (first, _) = session(remembering: memory)
      let entry = try #require(first.entries.first { (Catalogue.song($0.id)?.patterns.count ?? 0) > 1 })
      first.open(entry)
      let chosen = try #require(first.song?.patterns[1].id)
      first.editing = chosen

      let (next, _) = session(remembering: memory)
      next.restore()
      #expect(next.editing == chosen)
      #expect(next.shownPattern?.id == chosen)

      next.editing = nil
      let (again, _) = session(remembering: memory)
      again.restore()
      #expect(again.editing == nil)

      again.editing = chosen
      let other = try #require(again.entries.first { $0.id != entry.id })
      again.open(other)
      #expect(again.editing == nil)
      let (last, _) = session(remembering: memory)
      last.restore()
      #expect(last.current?.id == other.id)
      #expect(last.editing == nil)
    }
  }

  #if canImport(Darwin)
    /// Through a bookmark, so a document renamed in the Finder since is still found.
    @Test func aDocumentComesBackEvenAfterBeingRenamed() throws {
      try withMemory { memory in
        try withTemporaryDirectory { directory in
          let url = directory.appendingPathComponent("Before.song.json")
          try Data(SongCodec.encode(steadySong(bpm: 131)).utf8).write(to: url)
          let (first, _) = session(remembering: memory)
          first.open(file: url)

          let renamed = directory.appendingPathComponent("After.song.json")
          try FileManager.default.moveItem(at: url, to: renamed)

          let (next, _) = session(remembering: memory)
          next.restore()
          #expect(next.song?.bpm == 131)
          #expect(next.fileURL?.lastPathComponent == "After.song.json")
          #expect(next.documentName == "After")
        }
      }
    }
  #else
    /// Through its path, where there are no bookmarks to follow a document that has moved.
    @Test func aDocumentComesBackFromWhereItWas() throws {
      try withMemory { memory in
        try withTemporaryDirectory { directory in
          let url = directory.appendingPathComponent("Before.song.json")
          try Data(SongCodec.encode(steadySong(bpm: 131)).utf8).write(to: url)
          let (first, _) = session(remembering: memory)
          first.open(file: url)
          #expect(memory.string(forKey: SessionDefaults.lastFile) == url.path)

          let (next, _) = session(remembering: memory)
          next.restore()
          #expect(next.song?.bpm == 131)
          #expect(next.fileURL?.lastPathComponent == "Before.song.json")
          #expect(next.documentName == "Before")
        }
      }
    }
  #endif

  /// Gone is forgotten rather than reported: there is nothing anyone can do about a file that
  /// was deleted between two launches, and an error about it at startup is just noise.
  @Test func aDocumentThatHasGoneIsForgotten() throws {
    try withMemory { memory in
      try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("Gone.song.json")
        try Data(SongCodec.encode(steadySong()).utf8).write(to: url)
        let (first, _) = session(remembering: memory)
        first.open(file: url)
        try FileManager.default.removeItem(at: url)

        let (next, _) = session(remembering: memory)
        next.restore()
        #expect(next.song == nil)
        #expect(next.error == nil)
        #expect(memory.object(forKey: SessionDefaults.lastFile) == nil)
      }
    }
  }

  /// Saving somewhere new moves the memory with it.
  @Test func savingAsSomewhereElseIsWhatComesBack() throws {
    try withMemory { memory in
      try withTemporaryDirectory { directory in
        let (first, _) = session(remembering: memory)
        let entry = try #require(first.entries.first)
        first.open(entry)
        let copy = directory.appendingPathComponent("My Copy.song.json")
        first.save(to: copy)

        let (next, _) = session(remembering: memory)
        next.restore()
        #expect(next.fileURL?.lastPathComponent == "My Copy.song.json")
        #expect(memory.string(forKey: SessionDefaults.lastSong) == nil)
      }
    }
  }

  /// A new song has nowhere to come back from, and quitting has already asked whether to save it.
  @Test func aNewSongLeavesNothingToRestore() throws {
    try withMemory { memory in
      let (first, _) = session(remembering: memory)
      let entry = try #require(first.entries.first)
      first.open(entry)
      first.new()

      let (next, _) = session(remembering: memory)
      next.restore()
      #expect(next.song == nil)
    }
  }

  /// A session made without memory keeps none, which is what lets every other test open files
  /// without rewriting what the application opens next.
  @Test func aSessionWithoutMemoryRemembersNothing() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      #expect(session.memory == nil)
      session.restore()
    }
  }
}
