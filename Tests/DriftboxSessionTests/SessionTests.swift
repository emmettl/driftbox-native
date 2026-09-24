import DriftboxEngine
import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// What the session does outside the song: the pad, the keys, and the switches that decide which
/// end of a MIDI cable the transport belongs to.
@MainActor
struct SessionTests {
  @Test func strikingAVoicePlaysItNowAndTheGridHearsAboutIt() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      // Stopped, so the only thing the engine reports is what was asked for by hand.
      session.stop()
      renderAudio(host, frames: 512)
      session.tick()
      _ = session.takeEvents()

      #expect(session.usedVoices.map(\.id) == ["909.bd"])
      session.strike(index: 0, accent: true)
      renderAudio(host, frames: 512)
      session.tick()

      let events = session.takeEvents()
      #expect(events.contains { $0.kind == .hit })
      let voice = try #require(allVoices.firstIndex { $0.id == "909.bd" })
      #expect(session.struck.contains(voice))
      // Taken once: the scene has had them and the next frame starts again.
      #expect(session.takeEvents().isEmpty)
      #expect(session.peaks.left > 0)

      // A lane the grid does not show is not something the keys can strike.
      session.strike(index: 9, accent: false)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(!session.takeEvents().contains { $0.kind == .hit })
    }
  }

  @Test func aNoteOnTheKeysPlaysThe303() throws {
    try withTemporaryDirectory { directory in
      let (session, host) = try openedSession(steadySong(), in: directory)
      session.stop()
      renderAudio(host, frames: 512)
      session.tick()
      _ = session.takeEvents()

      session.playNote(semitone: 5, accent: true)
      renderAudio(host, frames: 512)
      session.tick()
      #expect(session.takeEvents().contains { $0.kind == .note })
    }
  }

  @Test func theTouchOnThePadIsWhereTheSceneDrawsIt() throws {
    try withTemporaryDirectory { directory in
      let (session, _) = try openedSession(steadySong(), in: directory)
      #expect(session.padTouch == nil)
      session.pad(x: 0.25, y: 0.75)
      #expect(session.padTouch == SIMD2<Float>(0.25, 0.75))
      session.padRelease()
      #expect(session.padTouch == nil)
    }
  }

  /// Following and sending at once is a ring, since the virtual source is a source like any other,
  /// so turning either on turns the other off.
  @Test func theClockIsFollowedOrSentAndNeverBoth() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    #expect(!session.followsClock && !session.sendsClock)

    session.followsClock = true
    session.sendsClock = true
    #expect(!session.followsClock)

    session.followsClock = true
    #expect(!session.sendsClock)

    session.sendsClock = false
    #expect(!session.sendsClock)
  }

  /// Moving the clock to another port is not something a session without one can do anything
  /// about, but it must not be something it falls over doing.
  @Test func theClockCanBePointedSomewhereElse() {
    let session = Session(host: EngineHost(sampleRate: 48000))
    #expect(session.clockDestination == .virtual)
    #expect(session.clockDestinations.isEmpty)
    session.clockDestination = .port("Elektron")
    #expect(session.clockDestination == .port("Elektron"))
    session.clockDestination = .port("Elektron")
    session.clockDestination = .virtual
    #expect(session.clockDestination == .virtual)
    #expect(session.midiSources.isEmpty)
  }

  /// Driftbox's own port has no name, and the empty string is how the preference says so.
  @Test func aDestinationIsRememberedByName() {
    #expect(MIDIDestination.virtual.stored == "")
    #expect(MIDIDestination.port("Elektron").stored == "Elektron")
    #expect(MIDIDestination(stored: "") == .virtual)
    #expect(MIDIDestination(stored: "Elektron") == .port("Elektron"))
  }
}
