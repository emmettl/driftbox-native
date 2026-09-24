#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxHost
  import DriftboxSeq
  import DriftboxSession
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

    private func files(_ player: Session, asking asked: Asked) -> SongFiles {
      SongFiles(player: player) { name in
        asked.names.append(name)
        return asked.answer
      }
    }

    /// A song that has never had a file is a Save As in disguise, and one that has is not.
    @Test func saveAsksWhereOnlyWhenTheSongHasNoFileOfItsOwn() throws {
      withTemporaryDirectory { directory in
        let player = Session(host: EngineHost(sampleRate: 48000))
        let asked = Asked()
        let files = files(player, asking: asked)
        asked.answer = directory.appendingPathComponent("Fresh.driftbox")

        player.new()
        #expect(files.save())
        #expect(asked.names == ["Untitled.driftbox"])
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
        let player = Session(host: EngineHost(sampleRate: 48000))
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

  }
#endif
