#if os(Linux)
  import DriftboxHost
  import DriftboxHostLinux
  import Foundation
  import Synchronization
  import Testing

  private final class SilentSource: @unchecked Sendable {
    let calls = Atomic<Int>(0)
    var source: RenderSource {
      RenderSource(
        context: Unmanaged.passUnretained(self).toOpaque(),
        render: { context, frames, left, right in
          Unmanaged<SilentSource>.fromOpaque(context)._withUnsafeGuaranteedRef {
            _ = $0.calls.add(1, ordering: .relaxed)
          }
          left.update(repeating: 0, count: frames)
          right.update(repeating: 0, count: frames)
        }, sampleRate: 48000, owner: self)
    }
  }

  @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_PIPEWIRE"] == "1"))
  @MainActor struct PipeWireRouteTests {
    private func eventually(_ condition: () -> Bool) async throws {
      let began = HostTime.now()
      while !condition() {
        guard HostTime.seconds(from: began, to: HostTime.now()) < 12 else {
          throw PipeWireError("Timed out waiting for route transition")
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    }

    // The process owns its virtual sink. Termination removes only that test object. Neither
    // these tests nor the route changes the system default or any hardware configuration.
    private func sink(_ name: String) throws -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pw-cli")
      process.arguments = [
        "-m", "create-node", "adapter",
        "{ factory.name = support.null-audio-sink node.name = \(name) node.description = \(name) media.class = Audio/Sink audio.position = [ FL FR ] priority.session = 0 }",
      ]
      process.standardInput = Pipe()
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      return process
    }
    private func stop(_ process: Process) {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    private func command(_ arguments: [String]) throws -> Data {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/" + arguments[0])
      process.arguments = Array(arguments.dropFirst())
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw PipeWireError("Test command failed: \(arguments[0])")
      }
      return data
    }

    private func streamIDs(_ objects: [[String: Any]]) -> Set<Int> {
      let clients = Set(
        objects.compactMap { object -> Int? in
          guard object["type"] as? String == "PipeWire:Interface:Client",
            let props = (object["info"] as? [String: Any])?["props"] as? [String: Any],
            String(describing: props["application.process.id"] ?? "")
              == String(ProcessInfo.processInfo.processIdentifier)
          else { return nil }
          return object["id"] as? Int
        })
      return Set(
        objects.compactMap { object -> Int? in
          guard object["type"] as? String == "PipeWire:Interface:Node",
            let props = (object["info"] as? [String: Any])?["props"] as? [String: Any],
            props["node.name"] as? String == "driftbox-play", let client = props["client.id"] as? Int,
            clients.contains(client)
          else { return nil }
          return object["id"] as? Int
        })
    }

    private func linked(to name: String) throws -> Bool {
      let objects = try #require(
        try JSONSerialization.jsonObject(with: command(["pw-dump"])) as? [[String: Any]])
      let nodes = objects.filter { $0["type"] as? String == "PipeWire:Interface:Node" }
      let inputs = Set(
        nodes.compactMap { node -> Int? in
          let props = (node["info"] as? [String: Any])?["props"] as? [String: Any]
          return props?["node.name"] as? String == name ? node["id"] as? Int : nil
        })
      let outputs = streamIDs(objects)
      return objects.contains { node in
        guard node["type"] as? String == "PipeWire:Interface:Link",
          let info = node["info"] as? [String: Any],
          let output = info["output-node-id"] as? Int, let input = info["input-node-id"] as? Int
        else { return false }
        return outputs.contains(output) && inputs.contains(input) && info["state"] as? String == "active"
      }
    }

    @Test func selectedSinkFallsBackAndReturnsWithSourcesStillAttached() async throws {
      let name = "driftbox-test-" + UUID().uuidString.lowercased()
      var device = try sink(name)
      defer { stop(device) }
      let route = PipeWireRoute()
      defer { route.stop() }
      var changes = 0
      route.onChange = { changes += 1 }
      route.chosen = name
      let source = SilentSource()
      route.attach(source.source)  // Also covers attaching during discovery/negotiation.
      try await eventually { route.current?.id == name && source.calls.load(ordering: .relaxed) > 0 }
      #expect(route.error == nil)
      #expect(try linked(to: name))
      #expect(route.devices.contains { $0.id == name })
      let fallback = try #require(route.systemDefault)
      try #require(fallback.id != name)
      let before = route.renderedFrames
      stop(device)
      try await eventually { route.current == fallback && !route.devices.contains { $0.id == name } }
      #expect(route.chosen == name)
      #expect(try linked(to: fallback.id))
      device = try sink(name)
      try await eventually { route.current?.id == name && route.renderedFrames > before }
      #expect(try linked(to: name))
      route.chosen = nil
      try await eventually { route.current == route.systemDefault }
      #expect(try linked(to: fallback.id))
      #expect(changes >= 4)
      route.detach(source.source.context)
      let calls = source.calls.load(ordering: .relaxed)
      try await Task.sleep(for: .milliseconds(400))
      #expect(source.calls.load(ordering: .relaxed) == calls)
    }

    @Test func lostStreamReopensAndDetachedOwnerNeverReturns() async throws {
      let name = "driftbox-test-" + UUID().uuidString.lowercased()
      let device = try sink(name)
      defer { stop(device) }
      let route = PipeWireRoute()
      defer { route.stop() }
      route.chosen = name
      var source: SilentSource? = SilentSource()
      weak let owner = source
      let context = source!.source.context
      route.attach(source!.source)
      source = nil
      try await eventually { route.current?.id == name && route.renderedFrames > 0 }
      let objects = try #require(
        try JSONSerialization.jsonObject(with: command(["pw-dump"])) as? [[String: Any]])
      let streams = streamIDs(objects)
      // Only this process's stream is eligible; never destroy another application's node.
      let id = try #require(streams.count == 1 ? streams.first : nil)
      let before = route.renderedFrames
      _ = try command(["pw-cli", "destroy", String(id)])
      try await eventually { route.current == nil && route.error != nil }
      try await eventually { route.current?.id == name && route.renderedFrames > before }
      #expect(owner != nil)
      route.detach(context)
      #expect(owner == nil)
      // Another route change must not resurrect a source detached before reopening.
      route.chosen = nil
      try await eventually { route.current == route.systemDefault }
      #expect(owner == nil)
      route.stop()
      route.chosen = name
      try await Task.sleep(for: .milliseconds(500))
      #expect(route.current == nil)
      #expect(route.devices.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_RECOVERY_DIRECTORY"] != nil))
    func serverRestartKeepsSourcesAndDetachingOfflineReleasesOwner() async throws {
      let directory = URL(
        fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DRIFTBOX_TEST_RECOVERY_DIRECTORY"])
      )
      func stage(_ value: String) throws {
        try value.write(to: directory.appendingPathComponent("stage"), atomically: true, encoding: .utf8)
      }
      let route = PipeWireRoute()
      defer { route.stop() }
      var original: SilentSource? = SilentSource()
      weak let oldOwner = original
      let context = original!.source.context
      route.attach(original!.source)
      original = nil
      try await eventually { route.current != nil && route.renderedFrames > 0 }
      let before = route.renderedFrames
      try stage("ready")
      try await eventually { route.current == nil && route.devices.isEmpty && route.error != nil }
      #expect(oldOwner != nil)
      route.detach(context)
      #expect(oldOwner == nil)
      let replacement = SilentSource()
      route.attach(replacement.source)
      try stage("offline")
      try await eventually {
        route.current != nil && route.renderedFrames > before
          && replacement.calls.load(ordering: .relaxed) > 0
      }
      #expect(route.error == nil)
      #expect(oldOwner == nil)
      #expect(try linked(to: try #require(route.current).id))
      try stage("recovered")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_RECOVERY_DIRECTORY"] != nil))
    func defaultChangesAreFollowedUnlessADeviceIsChosen() async throws {
      let name = "driftbox-test-" + UUID().uuidString.lowercased()
      let device = try sink(name)
      defer { stop(device) }
      let route = PipeWireRoute()
      defer { route.stop() }
      let source = SilentSource()
      route.attach(source.source)
      try await eventually { route.current != nil && route.devices.contains { $0.id == name } }
      let original = try #require(route.systemDefault)
      try #require(original.id != name)
      // This test is enabled only by the private-server harness. Metadata writes are confined
      // to that temporary server; ordinary opt-in tests never change desktop preferences.
      let value = String(decoding: try JSONEncoder().encode(["name": name]), as: UTF8.self)
      _ = try command(["pw-metadata", "-n", "default", "0", "default.audio.sink", value, "Spa:String:JSON"])
      try await eventually { route.systemDefault?.id == name && route.current?.id == name }
      #expect(try linked(to: name))
      route.chosen = original.id
      try await eventually { route.current == original }
      #expect(route.systemDefault?.id == name)
      #expect(try linked(to: original.id))
      route.chosen = nil
      try await eventually { route.current?.id == name }
      #expect(try linked(to: name))
    }
  }
#endif
