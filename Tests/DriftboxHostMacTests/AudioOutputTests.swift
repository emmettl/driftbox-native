#if os(macOS)
  import AVFoundation
  import DriftboxHost
  import DriftboxHostMac
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

    @Test func aRouteStartsTheEngineOnTheDeviceChosen() throws {
      guard let system = AudioOutputs.systemDefault() else { return }
      let engine = AVAudioEngine()
      let route = AudioRoute(engine: engine, chosen: system.uid)
      defer { engine.stop() }
      #expect(route.current == system.device)
      #expect(route.error == nil)
      #expect(engine.isRunning)
      #expect(route.devices.contains(system.device))
      #expect(route.systemDefault == system.device)
    }

    /// A choice that is not there — an interface left at the studio — plays through the system's
    /// device, and is still the choice.
    @Test func aMissingDeviceFallsBackToTheSystems() throws {
      guard let system = AudioOutputs.systemDefault() else { return }
      let engine = AVAudioEngine()
      let route = AudioRoute(engine: engine, chosen: "no-such-device")
      defer { engine.stop() }
      #expect(route.current == system.device)
      #expect(route.chosen == "no-such-device")
      #expect(engine.isRunning)
    }

    /// A source attached to the route is rendered by the device, and one detached is not: the
    /// port every platform's output answers. The source writes silence and counts its calls.
    @Test func anAttachedSourceIsPlayedAndADetachedOneIsNot() async throws {
      guard AudioOutputs.systemDefault() != nil else { return }
      final class Counter: @unchecked Sendable {
        let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        init() { calls.initialize(to: 0) }
        deinit { calls.deallocate() }
      }
      let counter = Counter()
      let source = RenderSource(
        context: UnsafeMutableRawPointer(counter.calls),
        render: { context, frames, left, right in
          left.update(repeating: 0, count: frames)
          right.update(repeating: 0, count: frames)
          context.assumingMemoryBound(to: Int.self).pointee += 1
        }, sampleRate: 48000, owner: counter)
      let route = AudioRoute()
      defer { route.engine.stop() }
      #expect(route.sampleRate == 48000)
      route.attach(source)
      for _ in 0..<200 where counter.calls.pointee < 3 { try await Task.sleep(for: .milliseconds(10)) }
      #expect(counter.calls.pointee >= 3, "rendered \(counter.calls.pointee) times")
      #expect(route.engine.isRunning)
      #expect(route.latency >= 0)

      route.detach(source.context)
      let after = counter.calls.pointee
      try await Task.sleep(for: .milliseconds(200))
      #expect(counter.calls.pointee == after, "no longer called once detached")
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
