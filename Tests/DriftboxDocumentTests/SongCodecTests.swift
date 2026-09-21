import ConformanceSupport
import DriftboxDocument
import Foundation
import Testing

struct SongCodecTests {
  /// Decoding loses nothing and encoding invents nothing: every catalogue song comes back as the
  /// bytes the web app wrote. The emitter asserts the reference can do the same.
  @Test(arguments: try Fixtures.songIds())
  func catalogueSongSurvivesTheRoundTrip(id: String) throws {
    let text = try Fixtures.text("documents/\(id).song.json")
    let song = try #require(SongCodec.decode(text))
    #expect(SongCodec.encode(song) == text)
  }

  struct RepairCase: Decodable, CustomTestStringConvertible {
    let name: String
    let input: String
    let output: String?
    var testDescription: String { name }
  }

  /// Older formats, hand edits and damage come out exactly as the reference repairs them —
  /// or are refused where it refuses.
  @Test(
    arguments: try JSONDecoder().decode(
      [RepairCase].self, from: Fixtures.data("documents-repair.json")))
  func repairsWhatTheReferenceRepairs(repair: RepairCase) {
    #expect(SongCodec.decode(repair.input).map(SongCodec.encode) == repair.output)
  }

  /// An empty argument list passes every parameterised test above. This one would not.
  @Test func theFixturesAreAllThere() throws {
    #expect(try Fixtures.songIds().count == 25)
    let repairs = try JSONDecoder().decode([RepairCase].self, from: Fixtures.data("documents-repair.json"))
    #expect(repairs.count == 19)
    #expect(repairs.filter { $0.output == nil }.count == 5)
  }
}
