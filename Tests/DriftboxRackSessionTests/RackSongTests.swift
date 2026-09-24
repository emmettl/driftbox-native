import ConformanceSupport
import DriftboxDocument
import DriftboxRack
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxRackSession

/// A patch that carries a groovebox song: the rack runs at its tempo and swing unless the patch
/// sets its own, and plays it beside itself when it runs.
@MainActor
struct RackSongTests {
  static func song() throws -> Song {
    try #require(SongCodec.decode(try Fixtures.text("documents/garage.song.json")))
  }

  static func model(_ song: Song, tempo: Double? = nil) -> RackSession {
    let model = RackSession()
    var patch = Patch(modules: [PatchModule(id: "song", type: "groovebox")], cables: [])
    patch.groovebox = SongCodec.encode(song)
    patch.tempo = tempo
    model.open(patch, name: "Song")
    return model
  }

  @Test func theRackRunsAtTheSongsTempoUnlessThePatchSetsOne() throws {
    let song = try Self.song()
    let model = Self.model(song)
    #expect(model.song == song)
    #expect(model.tempo == song.bpm)
    #expect(model.swing == song.swing)
    #expect(Self.model(song, tempo: 97).tempo == 97)

    model.setTempo(140)
    #expect(model.tempo == 140)
    #expect(model.patch.tempo == 140)
  }

  @Test func aPatchWithoutASongRunsAtItsOwn() {
    let model = RackSession()
    model.open(Patch(modules: [], cables: []), name: "Empty")
    #expect(model.song == nil)
    #expect(model.tempo == 120)
    #expect(model.swing == 0)
  }

  /// Listening, the rack plays the song when it runs, and not before.
  @Test func theRackPlaysItsSongWhenItRuns() throws {
    let song = try Self.song()
    let model = Self.model(song)
    model.listen()
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    func loudest() -> Float {
      var peak: Float = 0
      for _ in 0..<200 {
        model.host.render(frames: 128, left: left, right: right)
        for i in 0..<128 { peak = max(peak, abs(left[i]), abs(right[i])) }
      }
      return peak
    }
    #expect(loudest() == 0, "silent until it runs")
    model.toggleRunning()
    #expect(loudest() > 0.05)
    let playing = model.host.song.playing.load(ordering: .relaxed)
    #expect(playing)
    model.toggleRunning()
    _ = loudest()
    let stopped = model.host.song.playing.load(ordering: .relaxed)
    #expect(!stopped)
  }
}
