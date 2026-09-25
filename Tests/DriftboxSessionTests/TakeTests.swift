import DriftboxEngine
import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// A performance recorded as it is played: the engine as the take found it, then everything done to
/// it, at the frame it took effect on. Playing one again is the Mac app's `TakeTests`.
@MainActor
struct TakeTests {
  /// The engine rendered as a device would, in blocks of 512, with what it rendered kept.
  @MainActor
  final class Live {
    let session: Session
    var host: EngineHost { session.host }
    var left: [Float] = []
    var right: [Float] = []

    init(_ session: Session) { self.session = session }

    func play(_ frames: Int) {
      var l = [Float](repeating: 0, count: 512)
      var r = [Float](repeating: 0, count: 512)
      var done = 0
      while done < frames {
        let count = min(512, frames - done)
        l.withUnsafeMutableBufferPointer { lp in
          r.withUnsafeMutableBufferPointer { rp in
            host.render(frames: count, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
        left += l.prefix(count)
        right += r.prefix(count)
        done += count
      }
      // As the app ticks the session while it draws: how it learns the engine is playing.
      session.tick()
    }
  }

  /// A performance: play, the pad swept and let go, a key struck, a step edited as it plays, a
  /// jump back to the top, and a stop — recorded, and played again.
  static func performed() throws -> (take: Take, heard: (left: [Float], right: [Float]), start: Int) {
    let host = EngineHost(sampleRate: 48000)
    let session = Session(host: host)
    session.open(steadySong(), named: "Steady")
    let live = Live(session)
    live.play(4000)
    session.play()
    live.play(512)
    session.startRecording()
    let start = live.left.count
    live.play(30000)
    session.pad(x: 0.2, y: 0.8)
    live.play(3000)
    session.pad(x: 0.7, y: 0.3)
    live.play(6000)
    session.padRelease()
    live.play(4000)
    session.strike(index: 0, accent: true)
    live.play(7000)
    session.editShown("Set Step") { pattern in
      var pattern = pattern
      pattern.tracks["909.bd"]?[3] = .off
      return pattern
    }
    live.play(12000)
    session.seek(toStep: 0)
    live.play(8000)
    session.stop()
    live.play(10000)
    let take = try #require(session.stopRecording())
    return (take, (Array(live.left[start...]), Array(live.right[start...])), start)
  }

  @Test func aTakeIsWhatWasDoneAndWhen() throws {
    let (take, heard, _) = try Self.performed()
    #expect(take.playing)
    #expect(take.end - take.start == heard.left.count, "as long as what was heard")
    let kinds = take.events.map { event -> String in
      switch event.event {
      case .command(.pad): "pad"
      case .command(.padRelease): "release"
      case .command(.strike): "strike"
      case .command(.seek): "seek"
      case .command(.stop): "stop"
      case .command(.play): "play"
      case .command: "other"
      case .song(_, keepingPlace: true): "edit"
      case .song: "song"
      case .scene: "scene"
      }
    }
    // The edit is its song, kept where the engine had got to, and playing on.
    #expect(kinds == ["pad", "pad", "release", "strike", "edit", "play", "seek", "stop"], "\(kinds)")
    let frames = take.events.map(\.frame)
    #expect(frames == frames.sorted())
    #expect(frames.allSatisfy { $0 >= take.start && $0 <= take.end })
  }

  @Test func nothingIsRecordedUnlessAsked() throws {
    let session = Session(host: EngineHost(sampleRate: 48000))
    session.open(steadySong(), named: "Steady")
    session.play()
    #expect(session.stopRecording() == nil)
    #expect(!session.isRecording)
    session.startRecording(scene: "pulse")
    #expect(session.isRecording)
    session.noteScene("rain")
    let take = try #require(session.stopRecording())
    #expect(take.scene == "pulse")
    #expect(take.events.count == 1)
    #expect(!session.isRecording)
  }
}
