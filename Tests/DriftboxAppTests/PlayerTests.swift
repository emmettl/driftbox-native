#if canImport(AVFoundation)
  import DriftboxEngine
  import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// What the player does outside the song: the pad, the keys, and the switches that decide which
  /// end of a MIDI cable the transport belongs to.
  @MainActor
  struct PlayerTests {
    @Test func strikingAVoicePlaysItNowAndTheGridHearsAboutIt() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        // Stopped, so the only thing the engine reports is what was asked for by hand.
        player.stop()
        renderAudio(host, frames: 512)
        player.tick()
        _ = player.takeEvents()

        #expect(player.usedVoices.map(\.id) == ["909.bd"])
        player.strike(index: 0, accent: true)
        renderAudio(host, frames: 512)
        player.tick()

        let events = player.takeEvents()
        #expect(events.contains { $0.kind == .hit })
        let voice = try #require(allVoices.firstIndex { $0.id == "909.bd" })
        #expect(player.struck.contains(voice))
        // Taken once: the scene has had them and the next frame starts again.
        #expect(player.takeEvents().isEmpty)
        #expect(player.peaks.left > 0)
        #expect(player.analyse() != nil)

        // A lane the grid does not show is not something the keys can strike.
        player.strike(index: 9, accent: false)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(!player.takeEvents().contains { $0.kind == .hit })
      }
    }

    @Test func aNoteOnTheKeysPlaysThe303() throws {
      try withTemporaryDirectory { directory in
        let (player, host) = try openedPlayer(steadySong(), in: directory)
        player.stop()
        renderAudio(host, frames: 512)
        player.tick()
        _ = player.takeEvents()

        player.playNote(semitone: 5, accent: true)
        renderAudio(host, frames: 512)
        player.tick()
        #expect(player.takeEvents().contains { $0.kind == .note })
      }
    }

    @Test func theTouchOnThePadIsWhereTheSceneDrawsIt() throws {
      try withTemporaryDirectory { directory in
        let (player, _) = try openedPlayer(steadySong(), in: directory)
        #expect(player.padTouch == nil)
        player.pad(x: 0.25, y: 0.75)
        #expect(player.padTouch == SIMD2<Float>(0.25, 0.75))
        player.padRelease()
        #expect(player.padTouch == nil)
      }
    }

    /// Following and sending at once is a ring, since the virtual source is a source like any other,
    /// so turning either on turns the other off.
    @Test func theClockIsFollowedOrSentAndNeverBoth() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      #expect(!player.followsClock && !player.sendsClock)

      player.followsClock = true
      player.sendsClock = true
      #expect(!player.followsClock)

      player.followsClock = true
      #expect(!player.sendsClock)

      player.sendsClock = false
      #expect(!player.sendsClock)
    }

    /// Moving the clock to another port is not something a player without one can do anything
    /// about, but it must not be something it falls over doing.
    @Test func theClockCanBePointedSomewhereElse() {
      let player = Player(host: EngineHost(sampleRate: 48000))
      #expect(player.clockDestination == .virtual)
      #expect(player.clockDestinations.isEmpty)
      player.clockDestination = .port("Elektron")
      #expect(player.clockDestination == .port("Elektron"))
      player.clockDestination = .port("Elektron")
      player.clockDestination = .virtual
      #expect(player.clockDestination == .virtual)
      #expect(player.midiSources.isEmpty)
    }

    /// Driftbox's own port has no name, and the empty string is how the preference says so.
    @Test func aDestinationIsRememberedByName() {
      #expect(MIDIOutput.Destination.virtual.stored == "")
      #expect(MIDIOutput.Destination.port("Elektron").stored == "Elektron")
      #expect(MIDIOutput.Destination(stored: "") == .virtual)
      #expect(MIDIOutput.Destination(stored: "Elektron") == .port("Elektron"))
    }

    @Test func chanceIsARunOfNumbersBetweenNoneAndAll() {
      let random = chance()
      let values = (0..<32).map { _ in random() }
      #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
      #expect(Set(values).count > 1)
    }
  }
#endif
