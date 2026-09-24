import DriftboxDocument
import DriftboxHost
import DriftboxSeq
import Foundation
import Testing

@testable import DriftboxSession

/// The settings, kept in `memory` from one session to the next, under the keys the Mac app has
/// always kept them under, so that its preferences come with it when it moves onto the session.
@MainActor
struct SettingsTests {
  func withMemory<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "driftbox-settings-\(UUID().uuidString)"
    let memory = UserDefaults(suiteName: name)!
    defer { memory.removePersistentDomain(forName: name) }
    return try body(memory)
  }

  /// A MIDI input with no cables: what the session tells it is all there is to see.
  final class Cables: MIDIInputPort, @unchecked Sendable {
    var onNote: (@Sendable (Int, Double) -> Void)?
    var onMessage: (@Sendable ([UInt8]) -> Void)?
    var onClock: (@Sendable (ClockMessage, Double) -> Void)?
    var onSourcesChange: (@Sendable ([String]) -> Void)?
    var sources = ["Keys", "Elektron"]
    var ignoring: Set<String> = []
  }

  /// Somewhere to play through with no device behind it: what the session chose is all there is
  /// to see.
  final class Speakers: AudioRouting {
    var chosen: String?
    var devices: [AudioDevice] = []
    var current: AudioDevice?
    var systemDefault: AudioDevice?
    var error: String?
    var onChange: (() -> Void)?
    var sampleRate: Double { 48000 }
    var latency: Double { 0 }
    func attach(_ source: RenderSource) {}
    func detach(_ context: UnsafeMutableRawPointer) {}
  }

  /// Reading the settings writes none of them back: a session that changes nothing leaves the
  /// preferences as it found them, as the Mac app's, which writes a key only when it changes.
  @Test func readingTheSettingsWritesNothing() {
    withMemory { memory in
      _ = Session(host: EngineHost(sampleRate: 48000), audio: Speakers(), midiIn: Cables(), memory: memory)
      let keys = [
        "visuals.run", "midi.listens", "midi.ignored", "clock.sends", "transport.metronome",
        "transport.countIn", "clock.destination", "audio.output",
      ]
      for key in keys {
        #expect(memory.object(forKey: key) == nil, "\(key) was written")
      }
    }
  }

  /// Nothing remembered is every setting as it comes.
  @Test func aSessionWithNothingRememberedStartsFromTheDefaults() {
    withMemory { memory in
      let session = Session(host: EngineHost(sampleRate: 48000), memory: memory)
      #expect(session.showsVisuals)
      #expect(session.listensToMIDI)
      #expect(session.ignoredMIDISources.isEmpty)
      #expect(!session.metronome)
      #expect(!session.countsIn)
      #expect(!session.sendsClock)
      #expect(!session.followsClock)
      #expect(session.clockDestination == .virtual)
      #expect(session.outputDevice == nil)
    }
  }

  /// Every setting made in one session is there in the next.
  @Test func settingsComeBackInANewSession() {
    withMemory { memory in
      let first = Session(host: EngineHost(sampleRate: 48000), memory: memory)
      first.showsVisuals = false
      first.listensToMIDI = false
      first.ignoredMIDISources = ["Elektron", "Beatstep"]
      first.metronome = true
      first.countsIn = true
      first.clockDestination = .port("Elektron")
      first.sendsClock = true
      first.outputDevice = "{0.0.0.00000000}.{speakers}"

      let next = Session(host: EngineHost(sampleRate: 48000), memory: memory)
      #expect(!next.showsVisuals)
      #expect(!next.listensToMIDI)
      #expect(next.ignoredMIDISources == ["Elektron", "Beatstep"])
      #expect(next.metronome)
      #expect(next.countsIn)
      #expect(next.clockDestination == .port("Elektron"))
      #expect(next.sendsClock)
      #expect(!next.followsClock)
      #expect(next.outputDevice == "{0.0.0.00000000}.{speakers}")
    }
  }

  /// The Mac app's keys, and its way of writing each: the sources ignored one name to a line, and
  /// the empty string for the system's device and for the app's own port, neither of which has a
  /// name of its own.
  @Test func settingsAreRememberedUnderTheMacAppsKeys() {
    withMemory { memory in
      let session = Session(host: EngineHost(sampleRate: 48000), memory: memory)
      session.showsVisuals = false
      session.listensToMIDI = false
      session.ignoredMIDISources = ["Elektron", "Beatstep"]
      session.metronome = true
      session.countsIn = true
      session.clockDestination = .port("Elektron")
      session.sendsClock = true
      session.outputDevice = "{0.0.0.00000000}.{speakers}"

      #expect(memory.object(forKey: "visuals.run") as? Bool == false)
      #expect(memory.object(forKey: "midi.listens") as? Bool == false)
      #expect(memory.string(forKey: "midi.ignored") == "Beatstep\nElektron")
      #expect(memory.bool(forKey: "transport.metronome"))
      #expect(memory.bool(forKey: "transport.countIn"))
      #expect(memory.string(forKey: "clock.destination") == "Elektron")
      #expect(memory.bool(forKey: "clock.sends"))
      #expect(memory.string(forKey: "audio.output") == "{0.0.0.00000000}.{speakers}")

      session.outputDevice = nil
      #expect(memory.string(forKey: "audio.output") == "")
      session.clockDestination = .virtual
      #expect(memory.string(forKey: "clock.destination") == "")
      session.metronome = false
      #expect(memory.object(forKey: "transport.metronome") as? Bool == false)
      // Following the clock turns sending it off, and that is remembered too.
      session.followsClock = true
      #expect(memory.object(forKey: "clock.sends") as? Bool == false)
      session.ignoredMIDISources = []
      #expect(memory.string(forKey: "midi.ignored") == "")
    }
  }

  /// What the Mac app wrote, the session reads: the preferences come with the app.
  @Test func whatTheMacAppRememberedIsRead() {
    withMemory { memory in
      memory.set(false, forKey: "visuals.run")
      memory.set(false, forKey: "midi.listens")
      memory.set("Keys\nElektron", forKey: "midi.ignored")
      memory.set(true, forKey: "transport.metronome")
      memory.set(true, forKey: "transport.countIn")
      memory.set("Elektron", forKey: "clock.destination")
      memory.set(true, forKey: "clock.sends")
      memory.set("BuiltInSpeakerDevice", forKey: "audio.output")

      let session = Session(host: EngineHost(sampleRate: 48000), memory: memory)
      #expect(!session.showsVisuals)
      #expect(!session.listensToMIDI)
      #expect(session.ignoredMIDISources == ["Keys", "Elektron"])
      #expect(session.metronome)
      #expect(session.countsIn)
      #expect(session.clockDestination == .port("Elektron"))
      #expect(session.sendsClock)
      #expect(session.outputDevice == "BuiltInSpeakerDevice")
    }
  }

  /// Remembered settings reach what they control, not only the session's own properties: the
  /// device chosen, the sources ignored, and a count-in the engine counts.
  @Test func rememberedSettingsReachWhatTheyControl() throws {
    try withMemory { memory in
      memory.set("Elektron", forKey: "midi.ignored")
      memory.set("BuiltInSpeakerDevice", forKey: "audio.output")
      memory.set(true, forKey: "transport.countIn")

      let cables = Cables()
      let speakers = Speakers()
      let host = EngineHost(sampleRate: 48000)
      let session = Session(host: host, audio: speakers, midiIn: cables, memory: memory)
      #expect(cables.ignoring == ["Elektron"])
      #expect(session.midiSources == ["Keys", "Elektron"])
      #expect(speakers.chosen == "BuiltInSpeakerDevice")

      session.outputDevice = nil
      #expect(speakers.chosen == nil)
      session.ignoredMIDISources = []
      #expect(cables.ignoring.isEmpty)

      try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("Test.song.json")
        try Data(SongCodec.encode(steadySong()).utf8).write(to: url)
        session.open(file: url)
        session.stop()
        renderAudio(host, frames: 512)
        session.seek(toStep: 0)
        session.play()
        renderAudio(host, frames: 48000)
        session.tick()
        #expect(session.countingIn)
        #expect(session.songFrame == 0)
      }
      session.close()
    }
  }
}
