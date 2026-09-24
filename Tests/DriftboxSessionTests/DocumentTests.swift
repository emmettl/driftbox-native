import DriftboxDocument
import DriftboxHost
import DriftboxSeq
import DriftboxSession
import Foundation
import Testing

/// What makes a song a document: the name it goes by, the mark that says there is unsaved work,
/// and where Save writes.
@MainActor
struct DocumentTests {
  @Test func aSongOpenedFromAFileIsNamedAfterItAndIsNotEdited() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), named: "Night Bus", in: directory)
      #expect(session.song != nil)
      // Both halves of `.song.json` come off; what is left is what the window is called.
      #expect(session.documentName == "Night Bus")
      #expect(session.fileURL == directory.appendingPathComponent("Night Bus.song.json"))
      #expect(!session.isEdited)
    }
  }

  @Test func aSongFromTheCatalogueIsNamedAfterItsEntry() throws {
    let session = Session(host: EngineHost(sampleRate: 48000))
    let entry = try #require(session.entries.first)
    session.open(entry)
    #expect(session.song != nil)
    #expect(session.documentName == entry.name)
    // It came from the bundle rather than from disk, so Save has nowhere of its own to go.
    #expect(session.fileURL == nil)
    #expect(!session.isEdited)
  }

  /// A window with no song in it is not an untitled document, it is the application waiting.
  @Test func aWindowWithNoSongIsJustTheApplication() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    #expect(session.documentName == "Driftbox")
    // A new song is one of its own, unnamed and unedited until something is done to it.
    session.new()
    #expect(session.documentName == "Untitled")
    #expect(session.fileURL == nil)
    #expect(!session.isEdited)
    #expect(session.song?.patterns.first?.length == 16)
  }

  @Test func anEditMarksTheDocumentAndOpeningAndSavingClearTheMark() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      #expect(!session.isEdited)

      session.edit("Set Tempo") { $0.bpm = 128 }
      #expect(session.isEdited)

      // Undoing back to what is on disk is back to saved: there is nothing left to save.
      session.undo()
      #expect(session.song?.bpm == 120)
      #expect(!session.isEdited)
      session.redo()
      #expect(session.isEdited)

      let elsewhere = directory.appendingPathComponent("Elsewhere.song.json")
      session.save(to: elsewhere)
      #expect(!session.isEdited)
      // Saving under a new name renames the window with it.
      #expect(session.documentName == "Elsewhere")
      #expect(session.fileURL == elsewhere)

      session.edit("Set Tempo") { $0.bpm = 140 }
      #expect(session.isEdited)
      session.open(file: directory.appendingPathComponent("Test.song.json"))
      #expect(!session.isEdited)
      #expect(session.song?.bpm == 120)
    }
  }

  @Test func savingWritesTheSongWhereTheFileWas() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      session.edit("Set Tempo") { $0.bpm = 128 }
      session.save()

      let url = directory.appendingPathComponent("Test.song.json")
      let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
      let written = try #require(SongCodec.decode(text))
      #expect(written.bpm == 128)
      #expect(!session.isEdited)
    }
  }

  /// Nothing to save is not a failure to save: a session with no file has nowhere to write, which
  /// is not an error.
  @Test func savingNothingSucceeds() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    session.save()
    #expect(session.error == nil)
  }

  @Test func aFileThatIsNotASongSaysSoAndChangesNothing() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      let rubbish = directory.appendingPathComponent("Rubbish.song.json")
      try Data("not a song".utf8).write(to: rubbish)

      session.open(file: rubbish)
      #expect(session.error == "Rubbish.song.json is not a song")
      #expect(session.documentName == "Test")
      #expect(session.fileURL != rubbish)
    }
  }

  @Test func aSongThatCannotBeWrittenSaysSo() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      session.save(to: directory.appendingPathComponent("no/such/place.song.json"))
      #expect(session.error != nil)
    }
  }
}
