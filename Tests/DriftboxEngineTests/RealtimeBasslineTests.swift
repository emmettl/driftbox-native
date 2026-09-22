import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

/// The real-time 303 against the offline one, on real lines from the catalogue: to the bit.
struct RealtimeBasslineTests {
  static let sampleRate = 48000.0

  @Test(arguments: ["acid", "smallhours", "pump", "orrery"])
  func aLineIsTheOfflineLineToTheBit(songId: String) throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/\(songId).song.json")))
    let plan = song.plan(bars: min(song.bars, 12))
    let notes = plan.flatMap { step in step.bass.filter { $0.voiceId == "303.a" } }
    #expect(!notes.isEmpty)
    let frames = Int((plan.last!.time + 1) * Self.sampleRate)

    // Offline, each note scheduled from the first frame at or after its time — which is when a
    // sequencer inside the render call would reach it.
    var offline = Bassline(sampleRate: Self.sampleRate)
    for hit in notes {
      offline.play(
        hit.note, at: hit.time, scheduledAt: (hit.time * Self.sampleRate).rounded(.up) / Self.sampleRate)
    }
    let expected = offline.render(frames: frames)

    var realtime = RealtimeBassline(sampleRate: Self.sampleRate)
    var pending = notes[...]
    var mine = [Float](repeating: 0, count: frames)
    for frame in 0..<frames {
      let time = Double(frame) / Self.sampleRate
      while let next = pending.first, next.time <= time {
        realtime.play(next.note, at: next.time)
        pending = pending.dropFirst()
      }
      mine[frame] = realtime.next(time: time)
    }

    let differences = zip(mine, expected).filter { $0 != $1 }.count
    #expect(differences == 0, "\(songId): \(differences) of \(frames) samples differ")
    #expect(mine.contains { $0 != 0 })
  }
}
