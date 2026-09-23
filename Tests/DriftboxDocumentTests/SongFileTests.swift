import DriftboxDocument
import Testing

struct SongFileTests {
  @Test func aSongIsSavedAsDriftbox() {
    #expect(SongFile.fileName(for: "Night Bus") == "Night Bus.driftbox")
  }

  /// Every name a song has been saved under comes off whole, whatever its case.
  @Test func theNameIsTheFilesWithoutItsEnding() {
    #expect(SongFile.name(fromFileName: "Night Bus.driftbox") == "Night Bus")
    #expect(SongFile.name(fromFileName: "Night Bus.song.json") == "Night Bus")
    #expect(SongFile.name(fromFileName: "driftbox-song.json") == "driftbox-song")
    #expect(SongFile.name(fromFileName: "LOUD.DRIFTBOX") == "LOUD")
    #expect(SongFile.name(fromFileName: "v2.1.driftbox") == "v2.1")
  }

  /// A file called nothing but its ending, or with none Driftbox knows, keeps its whole name.
  @Test func aNameWithNothingLeftIsLeftAlone() {
    #expect(SongFile.name(fromFileName: ".driftbox") == ".driftbox")
    #expect(SongFile.name(fromFileName: "notes.txt") == "notes.txt")
  }

  @Test func songsAreOfferedByTheirEnding() {
    for name in ["a.driftbox", "a.song.json", "a.json", "A.Driftbox"] {
      #expect(SongFile.isSong(fileName: name))
    }
    for name in ["a.wav", "a.driftboxx", "driftbox", "a.patch"] {
      #expect(!SongFile.isSong(fileName: name))
    }
  }
}
