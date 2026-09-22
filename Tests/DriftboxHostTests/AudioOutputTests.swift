#if os(macOS)
  import AVFoundation
  import DriftboxHost
  import Foundation
  import Testing

  /// The devices sound can go out of, and an engine kept pointed at the right one. These run
  /// against whatever this Mac has, which is at least the device the system plays through; a
  /// machine with no audio device at all has nothing here to test.
  @MainActor
  struct AudioOutputTests {
    @Test func theSystemsOwnDeviceIsListedWithANameAndAUID() throws {
      guard let system = AudioOutputs.systemDefault() else { return }
      #expect(!system.uid.isEmpty && !system.name.isEmpty)
      #expect(AudioOutputs.all().contains(system))
    }

    @Test func theChosenDeviceIsPlayedThroughOnlyWhileItIsThere() {
      let speakers = AudioOutput(id: 1, uid: "speakers", name: "Speakers")
      let interface = AudioOutput(id: 2, uid: "interface", name: "Interface")
      #expect(
        AudioOutputs.pick(chosen: "interface", among: [speakers, interface], systemDefault: speakers)
          == interface)
      // Unplugged: the system's device, not silence.
      #expect(AudioOutputs.pick(chosen: "interface", among: [speakers], systemDefault: speakers) == speakers)
      #expect(
        AudioOutputs.pick(chosen: nil, among: [speakers, interface], systemDefault: interface) == interface)
      #expect(AudioOutputs.pick(chosen: nil, among: [], systemDefault: nil) == nil)
    }

    @Test func aRouteStartsTheEngineOnTheDeviceChosen() throws {
      guard let system = AudioOutputs.systemDefault() else { return }
      let engine = AVAudioEngine()
      let route = AudioRoute(engine: engine, chosen: system.uid)
      defer { engine.stop() }
      #expect(route.current == system)
      #expect(route.error == nil)
      #expect(engine.isRunning)
    }

    /// A choice that is not there — an interface left at the studio — plays through the system's
    /// device, and is still the choice.
    @Test func aMissingDeviceFallsBackToTheSystems() throws {
      guard let system = AudioOutputs.systemDefault() else { return }
      let engine = AVAudioEngine()
      let route = AudioRoute(engine: engine, chosen: "no-such-device")
      defer { engine.stop() }
      #expect(route.current == system)
      #expect(route.chosen == "no-such-device")
      #expect(engine.isRunning)
    }

    /// The engine stops itself when its device changes under it and posts this, and nothing
    /// starts it again unless something is listening. Before the route, nothing was: the sound
    /// went at the first change of output and stayed gone.
    @Test func anEngineStoppedByAChangeOfDeviceIsStartedAgain() async throws {
      guard AudioOutputs.systemDefault() != nil else { return }
      let engine = AVAudioEngine()
      var changes = 0
      let route = AudioRoute(engine: engine)
      route.onChange = { changes += 1 }
      defer { engine.stop() }
      engine.stop()
      NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
      for _ in 0..<100 where !engine.isRunning {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(engine.isRunning)
      #expect(changes >= 1)

      // Setting the output's device posts the same notification, so the route hears about its
      // own work too. That must come to rest rather than go round for ever.
      try await Task.sleep(for: .milliseconds(300))
      let settled = changes
      try await Task.sleep(for: .milliseconds(300))
      #expect(changes == settled)
      #expect(engine.isRunning)
    }
  }
#endif
