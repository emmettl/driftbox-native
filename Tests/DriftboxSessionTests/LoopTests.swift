import DriftboxHost
import DriftboxSeq
import DriftboxSession
import Foundation
import Testing

/// The transport's loop, metronome and count-in, from the session's side: what the controls
/// decide, and that it reaches the engine.
@MainActor
struct LoopTests {
  /// Four bars of one pattern, as four sections.
  func fourBars() -> Song {
    var song = steadySong()
    song.chain = (0..<4).map { _ in ChainStep(pattern: "p") }
    return song
  }

  @Test func aSectionLoopsAndUnloops() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    session.toggleLoop(start: 1, bars: 2)
    #expect(session.loop == Session.LoopRange(start: 1, bars: 2))
    session.toggleLoop(start: 1, bars: 2)
    #expect(session.loop == nil)
    // Stretching takes in whatever is between, on either side.
    session.toggleLoop(start: 2, bars: 1)
    session.extendLoop(toStart: 0, bars: 1)
    #expect(session.loop == Session.LoopRange(start: 0, bars: 3))
    session.extendLoop(toStart: 5, bars: 2)
    #expect(session.loop == Session.LoopRange(start: 0, bars: 7))
  }

  /// Set from the session, the engine goes round: four seconds of a two-second loop never leaves
  /// it.
  @Test func theLoopReachesTheEngine() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(fourBars(), in: directory)
      session.toggleLoop(start: 2, bars: 1)
      session.seek(toBar: 2)
      session.play()
      for _ in 0..<8 {
        renderAudio(host, frames: 24000)
        session.tick()
        #expect(session.position?.bar == 2)
      }
      // A different song is a different arrangement: the loop does not follow it.
      session.new()
      #expect(session.loop == nil)
    }
  }

  /// With a count-in, play waits a bar at the top while the clicks go, and says so.
  @Test func playCountsInAndAnEditDoesNot() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(fourBars(), in: directory)
      session.stop()
      renderAudio(host, frames: 512)
      session.seek(toStep: 0)
      session.countsIn = true
      session.play()
      renderAudio(host, frames: 48000)
      session.tick()
      #expect(session.countingIn)
      #expect(session.songFrame == 0)
      renderAudio(host, frames: 60000)
      session.tick()
      #expect(!session.countingIn)
      #expect(session.songFrame > 0)
      // An edit while playing re-sends play, which must not count in again.
      session.edit("Set Tempo") { $0.bpm = 121 }
      renderAudio(host, frames: 4800)
      session.tick()
      #expect(!session.countingIn)
    }
  }
}
