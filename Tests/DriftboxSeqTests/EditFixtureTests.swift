import ConformanceSupport
import DriftboxDSP
import DriftboxDocument
import DriftboxSeq
import Foundation
import Testing

/// Every editing transform, against what the reference makes of the same edit on the same song:
/// exactly, by way of the codec.
struct EditFixtureTests {
  struct Fixture: Decodable {
    struct Edit: Decodable {
      let name: String
      let output: String
    }
    let song: String
    let drum: String
    let bass: String
    let flams: [Bool]
    let trackLength: Int
    let edits: [Edit]
  }

  @Test func editsMatchTheReference() throws {
    let fixture = try JSONDecoder().decode(Fixture.self, from: Fixtures.data("edits.json"))
    let song = try #require(SongCodec.decode(fixture.song))
    let first = song.patterns[0]
    var withFlams = first
    withFlams.flams[fixture.drum] = fixture.flams
    withFlams.trackLengths[fixture.drum] = fixture.trackLength
    let drum = fixture.drum
    let bass = fixture.bass
    func random(_ seed: UInt32) -> RandomSource {
      var stream = SeededRandom(seed: seed)
      return { stream.next() }
    }
    func with(_ pattern: Pattern) -> Song {
      var out = song
      out.patterns = [pattern]
      return out
    }

    let mine: [String: () -> Song] = [
      "addPattern": { song.addingPattern().song },
      "addPattern twice": { song.addingPattern().song.addingPattern().song },
      "duplicatePattern": { song.duplicatingPattern(first.id).song },
      "duplicatePattern twice": { song.duplicatingPattern(first.id).song.duplicatingPattern(first.id).song },
      "renamePattern": { song.renamingPattern(first.id, to: "  Renamed  ") },
      "renamePattern to blank is refused": { song.renamingPattern(first.id, to: "   ") },
      "removePattern": { song.removingPattern(song.patterns[1].id) },
      "chainAppend": { song.appendingToChain(first.id) },
      "chainRemove": { song.removingFromChain(at: 1) },
      "chainSetRepeat": { song.settingChainRepeat(at: 0, to: 99) },
      "chainSetPattern": { song.settingChainPattern(at: 2, to: first.id) },
      "chainMove": { song.movingChainEntry(at: 0, by: 2) },
      "chainMove out of range": { song.movingChainEntry(at: 0, by: -1) },
      "rotateTrack": { with(withFlams.rotatingTrack(drum, by: 3)) },
      "rotateTrack backwards": { with(withFlams.rotatingTrack(drum, by: -7)) },
      "rotateBassLine": { with(first.rotatingBassLine(bass, by: 5)) },
      "transposeBassLine": { with(first.transposingBassLine(bass, by: 7)) },
      "transposeBassLine down past the floor": { with(first.transposingBassLine(bass, by: -30)) },
      "randomizeTrack": { with(withFlams.randomisingTrack(drum, random: random(0x1234))) },
      "randomizeBassLine": { with(first.randomisingBassLine(bass, random: random(0x1234))) },
      "alterTrack": { with(withFlams.alteringTrack(drum, random: random(0x4321))) },
      "alterBassLine": { with(first.alteringBassLine(bass, random: random(0x4321))) },
      "clearTrack": { with(withFlams.clearingTrack(drum)) },
      "clearBassLine": { with(first.clearingBassLine(bass)) },
      "setTrackLength": { with(first.settingTrackLength(drum, to: 6)) },
      "setTrackLength to full clears it": { with(withFlams.settingTrackLength(drum, to: 16)) },
      "toggleFlam on a rest": { with(first.togglingFlam(drum, at: 1)) },
      "toggleFlam off again": { with(first.togglingFlam(drum, at: 1).togglingFlam(drum, at: 1)) },
    ]
    #expect(fixture.edits.count == mine.count)
    for edit in fixture.edits {
      guard let apply = mine[edit.name] else {
        Issue.record("no Swift edit for \(edit.name)")
        continue
      }
      // Through the codec both ways, as the reference's result was, so what is compared is what
      // would be saved.
      let result = SongCodec.decode(SongCodec.encode(apply())).map(SongCodec.encode)
      #expect(result == edit.output, "\(edit.name)")
    }
  }
}
