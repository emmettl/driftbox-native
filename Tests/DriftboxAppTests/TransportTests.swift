#if canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// Where the interface thinks the song is. The engine is rendered by hand here, so the transport
  /// moves exactly as far as the test asked it to and no audio device is involved.
  @MainActor
  struct TransportTests {
    @Test func theTransportIsWhereTheEngineSaysItIs() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        #expect(player.currentStep == 0)
        #expect(player.position == Player.Position(bar: 0, step: 0, pattern: player.song?.patterns.first))

        // Half a second, which is four sixteenths at 120.
        renderAudio(host, frames: 24000)
        player.tick()
        #expect(player.isPlaying)
        #expect(player.currentStep == 4)
        #expect(player.position?.step == 4)
        #expect(player.position?.bar == 0)
        #expect(player.scoreBeat() == 1)

        // Half a step further on, which the scene sees although the step has not changed.
        renderAudio(host, frames: 3000)
        player.tick()
        #expect(player.currentStep == 4)
        #expect(player.position?.step == 4)
        #expect(try #require(player.scoreBeat()) == 1.125)
      }
    }

    @Test func aStoppedTransportHoldsItsPlace() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        renderAudio(host, frames: 24000)
        player.tick()
        #expect(player.currentStep == 4)

        player.stop()
        renderAudio(host, frames: 48000)
        player.tick()
        #expect(!player.isPlaying)
        #expect(player.currentStep == 4)
        #expect(player.scoreBeat() == 1)
        #expect(player.position?.step == 4)

        // And picks up from there rather than from the top.
        player.toggle()
        renderAudio(host, frames: 24000)
        player.tick()
        #expect(player.isPlaying)
        #expect(player.currentStep == 8)
      }
    }

    @Test func seekingMovesTheTransportToAStep() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        player.seek(toStep: 12)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.currentStep == 12)

        // A step off either end of the song lands on the step at that end.
        player.seek(toStep: 99)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.currentStep == 15)
        player.seek(toStep: -4)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.currentStep == 0)
      }
    }

    @Test func seekingMovesTheTransportToABarOfTheArrangement() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(changingSong(), in: directory)
        player.seek(toBar: 1)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.currentStep == 16)
        #expect(player.position?.bar == 1)
        #expect(player.position?.step == 0)
        #expect(player.position?.pattern?.id == "short")
      }
    }

    /// The chain's entries are where skipping lands, and it wraps at both ends because the chain
    /// does.
    @Test func skippingMovesAChainEntryAtATime() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(changingSong(), in: directory)
        #expect(player.sectionBars == [0, 1])

        player.skip(sections: 1)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.position?.bar == 1)

        player.skip(sections: 1)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.position?.bar == 0)

        player.skip(sections: -1)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.position?.bar == 1)
      }
    }

    /// A song with no arrangement is one section, and a player with no song has nowhere to be.
    @Test func aPlayerWithNoSongHasNoPosition() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      #expect(player.song == nil)
      #expect(player.position == nil)
      #expect(player.currentStep == 0)
      #expect(player.scoreBeat() == nil)
      #expect(player.sectionBars == [0])
      #expect(player.usedVoices.isEmpty)
      // None of these has anything to do, and none of them may fall over doing it.
      player.seek(toStep: 4)
      player.seek(toBar: 2)
      player.skip(sections: 1)
      player.play()
      player.stop()
      #expect(player.position == nil)
    }

    /// The tempo is the song's until an external clock is being followed.
    @Test func theTempoIsTheSongsOwn() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(bpm: 140), in: directory)
        #expect(player.tempo == 140)
        #expect(player.followedBPM == nil)
      }
    }
  }
#endif
