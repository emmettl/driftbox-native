#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// What makes a window a document: the name in its title bar, the dot that says there is unsaved
  /// work, and where Save writes.
  @MainActor
  struct DocumentTests {
    /// Somewhere for Save As to be answered from, since a panel has nobody to answer it here.
    @MainActor
    final class Asked {
      var names: [String] = []
      var answer: URL?
    }

    private func files(_ player: Player, asking asked: Asked) -> SongFiles {
      SongFiles(player: player) { name in
        asked.names.append(name)
        return asked.answer
      }
    }

    @Test func aSongOpenedFromAFileIsNamedAfterItAndIsNotEdited() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), named: "Night Bus", in: directory)
        #expect(player.song != nil)
        // Both halves of `.song.json` come off; what is left is what the window is called.
        #expect(player.documentName == "Night Bus")
        #expect(player.fileURL == directory.appendingPathComponent("Night Bus.song.json"))
        #expect(!player.isEdited)
      }
    }

    @Test func aSongFromTheCatalogueIsNamedAfterItsEntry() throws {
      let player = Player(host: EngineHost(sampleRate: 48000))
      let entry = try #require(player.entries.first)
      player.open(entry)
      #expect(player.song != nil)
      #expect(player.documentName == entry.name)
      // It came from the bundle rather than from disk, so Save has nowhere of its own to go.
      #expect(player.fileURL == nil)
      #expect(!player.isEdited)
    }

    /// A window with no song in it is not an untitled document, it is the application waiting.
    @Test func aWindowWithNoSongIsJustTheApplication() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      #expect(player.documentName == "Driftbox")
      // A new song is one of its own, unnamed and unedited until something is done to it.
      player.new()
      #expect(player.documentName == "Untitled")
      #expect(player.fileURL == nil)
      #expect(!player.isEdited)
      #expect(player.song?.patterns.first?.length == 16)
    }

    @Test func anEditMarksTheDocumentAndOpeningAndSavingClearTheMark() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        player.undoManager = UndoManager()
        #expect(!player.isEdited)

        player.edit("Set Tempo") { $0.bpm = 128 }
        #expect(player.isEdited)

        // Undoing back to what is on disk is back to saved, as it is in any Mac document: there
        // is nothing left to save. (This used to stay marked, which made quitting ask about
        // changes that were no longer there.)
        player.undo()
        #expect(player.song?.bpm == 120)
        #expect(!player.isEdited)
        player.redo()
        #expect(player.isEdited)

        let elsewhere = directory.appendingPathComponent("Elsewhere.song.json")
        player.save(to: elsewhere)
        #expect(!player.isEdited)
        // Saving under a new name renames the window with it.
        #expect(player.documentName == "Elsewhere")
        #expect(player.fileURL == elsewhere)

        player.edit("Set Tempo") { $0.bpm = 140 }
        #expect(player.isEdited)
        player.open(file: directory.appendingPathComponent("Test.song.json"))
        #expect(!player.isEdited)
        #expect(player.song?.bpm == 120)
      }
    }

    @Test func savingWritesTheSongWhereTheFileWas() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        player.edit("Set Tempo") { $0.bpm = 128 }
        player.save()

        let url = directory.appendingPathComponent("Test.song.json")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let written = try #require(SongCodec.decode(text))
        #expect(written.bpm == 128)
        #expect(!player.isEdited)
      }
    }

    /// A song that has never had a file is a Save As in disguise, and one that has is not.
    @Test func saveAsksWhereOnlyWhenTheSongHasNoFileOfItsOwn() throws {
      try withTemporaryDirectory { directory in
        let player = Player(host: EngineHost(sampleRate: 48000))
        let asked = Asked()
        let files = files(player, asking: asked)
        asked.answer = directory.appendingPathComponent("Fresh.song.json")

        player.new()
        #expect(files.save())
        #expect(asked.names == ["Untitled.song.json"])
        #expect(player.fileURL == asked.answer)
        #expect(!player.isEdited)

        // Now it has one, so Save has nothing to ask.
        player.edit("Set Tempo") { $0.bpm = 96 }
        #expect(files.save())
        #expect(asked.names.count == 1)
        #expect(!player.isEdited)
      }
    }

    @Test func aPanelNobodyAnsweredSavesNothing() throws {
      try withTemporaryDirectory { directory in
        let player = Player(host: EngineHost(sampleRate: 48000))
        let asked = Asked()
        let files = files(player, asking: asked)

        player.new()
        player.edit("Set Tempo") { $0.bpm = 96 }
        #expect(!files.saveAs())
        #expect(player.fileURL == nil)
        #expect(player.isEdited)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty)
      }
    }

    /// Nothing to save is not a failure to save: there is no window to keep open over it.
    @Test func savingNothingSucceeds() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      let asked = Asked()
      let files = files(player, asking: asked)
      #expect(files.save())
      #expect(files.saveAs())
      #expect(asked.names.isEmpty)
      // And the player's own save has nowhere to write, which is not an error either.
      player.save()
      #expect(player.error == nil)
    }

    @Test func aFileThatIsNotASongSaysSoAndChangesNothing() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        let rubbish = directory.appendingPathComponent("Rubbish.song.json")
        try Data("not a song".utf8).write(to: rubbish)

        player.open(file: rubbish)
        #expect(player.error == "Rubbish.song.json is not a song")
        #expect(player.documentName == "Test")
        #expect(player.fileURL != rubbish)
      }
    }

    @Test func aSongThatCannotBeWrittenSaysSo() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        player.save(to: directory.appendingPathComponent("no/such/place.song.json"))
        #expect(player.error != nil)
      }
    }
  }
#endif
