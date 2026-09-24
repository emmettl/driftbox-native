import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// Where the session thinks the song is. The engine is rendered by hand here, so the transport
/// moves exactly as far as the test asked it to and no audio device is involved.
@MainActor
struct TransportTests {
  @Test func theTransportIsWhereTheEngineSaysItIs() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      #expect(session.currentStep == 0)
      #expect(session.position == Session.Position(bar: 0, step: 0, pattern: session.song?.patterns.first))

      // Half a second, which is four sixteenths at 120.
      renderAudio(host, frames: 24000)
      session.tick()
      #expect(session.isPlaying)
      #expect(session.currentStep == 4)
      #expect(session.position?.step == 4)
      #expect(session.position?.bar == 0)
      #expect(session.scoreBeat() == 1)

      // Half a step further on, which the scene sees although the step has not changed.
      renderAudio(host, frames: 3000)
      session.tick()
      #expect(session.currentStep == 4)
      #expect(session.position?.step == 4)
      #expect(try #require(session.scoreBeat()) == 1.125)
    }
  }

  @Test func aStoppedTransportHoldsItsPlace() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      renderAudio(host, frames: 24000)
      session.tick()
      #expect(session.currentStep == 4)

      session.stop()
      renderAudio(host, frames: 48000)
      session.tick()
      #expect(!session.isPlaying)
      #expect(session.currentStep == 4)
      #expect(session.scoreBeat() == 1)
      #expect(session.position?.step == 4)

      // And picks up from there rather than from the top.
      session.toggle()
      renderAudio(host, frames: 24000)
      session.tick()
      #expect(session.isPlaying)
      #expect(session.currentStep == 8)
    }
  }

  @Test func seekingMovesTheTransportToAStep() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      session.seek(toStep: 12)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.currentStep == 12)

      // A step off either end of the song lands on the step at that end.
      session.seek(toStep: 99)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.currentStep == 15)
      session.seek(toStep: -4)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.currentStep == 0)
    }
  }

  @Test func seekingMovesTheTransportToABarOfTheArrangement() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(changingSong(), in: directory)
      session.seek(toBar: 1)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.currentStep == 16)
      #expect(session.position?.bar == 1)
      #expect(session.position?.step == 0)
      #expect(session.position?.pattern?.id == "short")
    }
  }

  /// The chain's entries are where skipping lands, and it wraps at both ends because the chain
  /// does.
  @Test func skippingMovesAChainEntryAtATime() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(changingSong(), in: directory)
      #expect(session.sectionBars == [0, 1])

      session.skip(sections: 1)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.position?.bar == 1)

      session.skip(sections: 1)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.position?.bar == 0)

      session.skip(sections: -1)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.position?.bar == 1)
    }
  }

  /// A song with no arrangement is one section, and a session with no song has nowhere to be.
  @Test func aSessionWithNoSongHasNoPosition() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    #expect(session.song == nil)
    #expect(session.position == nil)
    #expect(session.currentStep == 0)
    #expect(session.scoreBeat() == nil)
    #expect(session.sectionBars == [0])
    #expect(session.usedVoices.isEmpty)
    // None of these has anything to do, and none of them may fall over doing it.
    session.seek(toStep: 4)
    session.seek(toBar: 2)
    session.skip(sections: 1)
    session.play()
    session.stop()
    #expect(session.position == nil)
  }

  /// The tempo is the song's until an external clock is being followed.
  @Test func theTempoIsTheSongsOwn() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(bpm: 140), in: directory)
      #expect(session.tempo == 140)
      #expect(session.followedBPM == nil)
    }
  }
}
