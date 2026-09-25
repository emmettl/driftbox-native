import DriftboxDocument
import DriftboxHost
import DriftboxSeq
import Testing

@testable import DriftboxSession

/// A song document the platform reads and writes, where the session cannot — on Android, one the
/// storage access framework chose, named by a URI: opened from its text, and saved when the platform
/// says it has written it.
@MainActor
struct PlatformDocumentTests {
  static let location =
    "content://com.android.externalstorage.documents/document/primary%3AMusic%2FNight.driftbox"

  @Test func aDocumentOpensFromItsText() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    #expect(
      session.open(
        document: SongCodec.encode(steadySong(bpm: 133)), fileName: "Night.driftbox", at: Self.location))
    #expect(session.song?.bpm == 133)
    #expect(session.documentName == "Night", "named after its file, less the ending")
    #expect(session.current?.id == Self.location, "and known by where it is, for a save to go back to")
    #expect(!session.isEdited)
    #expect(session.fileURL == nil, "no path: only the platform can reach it")

    #expect(!session.open(document: "not a song", fileName: "Notes.driftbox", at: "content://x"))
    #expect(session.current?.id == Self.location, "the song open stays open")
    #expect(session.error == "Notes is not a song")
  }

  @Test func whatWasWrittenIsSaved() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    session.open(document: SongCodec.encode(steadySong()), fileName: "Night.driftbox", at: Self.location)
    session.edit { $0.bpm = 101 }
    #expect(session.isEdited)
    let handed = try! #require(session.song)
    // Edited again while the platform was writing: what it wrote is saved, and this is not.
    session.edit { $0.bpm = 102 }
    session.wrote(handed, to: "content://elsewhere", fileName: "Day.driftbox")
    #expect(session.isEdited)
    #expect(session.documentName == "Day")
    #expect(session.current?.id == "content://elsewhere")
    session.wrote(try! #require(session.song), to: "content://elsewhere", fileName: "Day.driftbox")
    #expect(!session.isEdited)

    session.couldNotWrite("Day.driftbox")
    #expect(session.error == "Day could not be saved")
  }
}
