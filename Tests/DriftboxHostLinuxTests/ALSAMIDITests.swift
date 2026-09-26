#if os(Linux)
  import DriftboxHost
  import DriftboxSeq
  @testable import DriftboxHostLinux
  import Foundation
  import Synchronization
  import Testing

  @Suite struct ALSAMIDIMessageTests {
    @Test func validatesCompleteShortMessages() {
      for message: [UInt8] in [
        [0x90, 60, 127], [0x80, 60, 0], [0xC2, 7], [0xD2, 5], [0xF2, 1, 2], [0xF8], [0xFA], [0xFC],
      ] {
        #expect(ALSAMIDI.valid(message))
      }
      for message: [UInt8] in [
        [], [60], [0x90], [0x90, 60], [0x90, 60, 128], [0xC0, 1, 2], [0xF0, 1, 0xF7], [0xF8, 0], [0xF4],
        [0xFD],
      ] {
        #expect(!ALSAMIDI.valid(message))
      }
    }
  }

  @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DRIFTBOX_TEST_ALSA"] == "1"))
  struct ALSAMIDITests {
    private func eventually(_ condition: () -> Bool) async throws {
      let start = HostTime.now()
      while !condition() {
        guard HostTime.seconds(from: start, to: HostTime.now()) < 5 else {
          throw ALSAMIDIError("Timed out waiting for software MIDI ports")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    @Test func messagesSchedulingIgnoringFlushAndVirtualOutput() async throws {
      let tag = "Driftbox Test " + UUID().uuidString
      let sender = try ALSAMIDI(name: tag + " Sender", connectsInputs: false)
      let receiver = try ALSAMIDI(name: tag + " Receiver")
      defer {
        receiver.stop()
        sender.stop()
      }
      let source = tag + " Sender: Output"
      let destination = MIDIDestination.port(tag + " Receiver: Input")
      try await eventually {
        receiver.sources.contains(source) && sender.destinations.contains(tag + " Receiver: Input")
      }
      receiver.ignoring = Set(receiver.sources.filter { $0 != source })
      let messages = Mutex<[([UInt8], UInt64)]>([])
      let notes = Mutex<[(Int, Double)]>([])
      let clocks = Mutex<[(ClockMessage, Double)]>([])
      receiver.onMessage = { bytes in messages.withLock { $0.append((bytes, HostTime.now())) } }
      receiver.onNote = { note, velocity in notes.withLock { $0.append((note, velocity)) } }
      receiver.onClock = { clock, time in clocks.withLock { $0.append((clock, time)) } }
      let due = HostTime.time(HostTime.now(), after: 0.2)
      #expect(sender.send([0x92, 60, 100], to: destination, at: due))
      try await Task.sleep(for: .milliseconds(60))
      #expect(messages.withLock { $0.isEmpty })
      try await eventually { messages.withLock { $0.count == 1 } }
      let first = try #require(messages.withLock { $0.first })
      #expect(first.0 == [0x92, 60, 100])
      #expect(HostTime.seconds(from: due, to: first.1) >= -0.002)
      #expect(HostTime.seconds(from: due, to: first.1) < 0.5)
      try await eventually { notes.withLock { $0.count == 1 } }
      #expect(notes.withLock { $0[0].0 == 60 && abs($0[0].1 - 100.0 / 127) < 1e-9 })

      #expect(sender.send([0x82, 60, 0], to: .virtual, at: HostTime.now()))
      #expect(sender.send([0xC2, 7], to: destination, at: HostTime.now()))
      #expect(sender.send([0xE2, 0, 64], to: destination, at: HostTime.now()))
      #expect(sender.send([0xFA], to: destination, at: HostTime.now()))
      #expect(sender.send([0xF8], to: destination, at: HostTime.now()))
      #expect(sender.send([0xF2, 1, 2], to: destination, at: HostTime.now()))
      try await eventually { messages.withLock { $0.count == 4 } && clocks.withLock { $0.count == 3 } }
      #expect(
        messages.withLock { $0.map(\.0) } == [
          [0x92, 60, 100], [0x82, 60, 0], [0xC2, 7, 0], [0xE2, 0, 64],
        ])
      #expect(notes.withLock { $0.last?.1 == 0 })
      #expect(clocks.withLock { $0.map(\.0) } == [.start, .tick, .position(step: 257)])
      #expect(clocks.withLock { $0.allSatisfy { $0.1.isFinite && $0.1 > 0 } })

      receiver.ignoring.insert(source)
      #expect(sender.send([0x90, 61, 127], to: destination, at: HostTime.now()))
      try await Task.sleep(for: .milliseconds(80))
      #expect(messages.withLock { $0.count == 4 })
      receiver.ignoring.remove(source)
      let later = HostTime.time(HostTime.now(), after: 0.15)
      #expect(sender.send([0x90, 62, 127], to: destination, at: later))
      #expect(sender.send([0x90, 63, 127], to: .virtual, at: later))
      sender.flush(destination)
      try await eventually { messages.withLock { $0.count == 5 } }
      #expect(messages.withLock { $0.last?.0 } == [0x90, 63, 127])
      #expect(!sender.send([0x90], to: destination, at: HostTime.now()))
      #expect(!sender.send([0x90, 60, 1], to: .port("missing"), at: HostTime.now()))
      #expect(sender.error == nil)
      #expect(receiver.error == nil)
      sender.stop()
      #expect(!sender.offersVirtualSource)
      #expect(!sender.send([0xF8], to: .virtual, at: HostTime.now()))
      #expect(sender.destinations.isEmpty)
    }

    @Test func hotplugNamesAndQueuedRemoval() async throws {
      let tag = "Driftbox Hotplug " + UUID().uuidString
      let host = try ALSAMIDI(name: tag + " Host")
      defer { host.stop() }
      let changes = Mutex<[[String]]>([])
      let incoming = Mutex<[[UInt8]]>([])
      host.onMessage = { bytes in incoming.withLock { $0.append(bytes) } }
      host.onSourcesChange = { names in changes.withLock { $0.append(names) } }
      var peer: ALSAMIDI? = try ALSAMIDI(name: tag + " Peer", connectsInputs: false)
      defer { peer?.stop() }
      let source = tag + " Peer: Output"
      let destination = tag + " Peer: Input"
      try await eventually { host.sources.contains(source) && host.destinations.contains(destination) }
      #expect(
        host.send([0x90, 65, 100], to: .port(destination), at: HostTime.time(HostTime.now(), after: 1)))
      peer?.stop()
      peer = nil
      try await eventually { !host.sources.contains(source) && !host.destinations.contains(destination) }
      #expect(!host.send([0x90, 60, 1], to: .port(destination), at: HostTime.now()))
      peer = try ALSAMIDI(name: tag + " Peer", connectsInputs: false)
      let received = Mutex<[[UInt8]]>([])
      peer?.onMessage = { bytes in received.withLock { $0.append(bytes) } }
      try await eventually { host.sources.contains(source) && host.destinations.contains(destination) }
      try await Task.sleep(for: .milliseconds(1100))
      #expect(received.withLock { $0.isEmpty })
      #expect(host.send([0x90, 66, 100], to: .port(destination), at: HostTime.now()))
      try await eventually { received.withLock { $0.count == 1 } }
      #expect(received.withLock { $0[0] } == [0x90, 66, 100])
      #expect(peer?.send([0x80, 66, 0], to: .virtual, at: HostTime.now()) == true)
      try await eventually { incoming.withLock { $0.contains([0x80, 66, 0]) } }
      #expect(
        changes.withLock { $0.contains { $0.contains(source) } && $0.contains { !$0.contains(source) } })
    }

    @Test func boundedQueueAndFinalStopDelivery() async throws {
      let tag = "Driftbox Drain " + UUID().uuidString
      let sender = try ALSAMIDI(name: tag + " Sender", connectsInputs: false)
      let receiver = try ALSAMIDI(name: tag + " Receiver")
      defer {
        sender.stop()
        receiver.stop()
      }
      let destination = MIDIDestination.port(tag + " Receiver: Input")
      try await eventually { sender.destinations.contains(tag + " Receiver: Input") }
      let future = HostTime.time(HostTime.now(), after: 60)
      for _ in 0..<16_384 { #expect(sender.send([0xF8], to: destination, at: future)) }
      #expect(!sender.send([0xF8], to: destination, at: future))
      sender.flush(destination)
      #expect(sender.send([0xF8], to: destination, at: future))
      let clocks = Mutex<[ClockMessage]>([])
      receiver.onClock = { message, _ in clocks.withLock { $0.append(message) } }
      #expect(sender.send([0xFC], to: destination, at: HostTime.now()))
      sender.stop()
      try await eventually { clocks.withLock { $0 == [.stop] } }
    }

    @Test func finalMessageSurvivesDiscoveryAfterSourceExit() async throws {
      let tag = "Driftbox Retired " + UUID().uuidString
      let sender = try ALSAMIDI(name: tag + " Sender", connectsInputs: false)
      let receiver = try ALSAMIDI(name: tag + " Receiver")
      let release = DispatchSemaphore(value: 0)
      defer {
        release.signal()
        receiver.stop()
        sender.stop()
      }
      let destination = MIDIDestination.port(tag + " Receiver: Input")
      try await eventually { sender.destinations.contains(tag + " Receiver: Input") }
      let entered = Mutex(false)
      let clocks = Mutex<[ClockMessage]>([])
      receiver.onMessage = { _ in
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 5)
      }
      receiver.onClock = { message, _ in clocks.withLock { $0.append(message) } }
      #expect(sender.send([0x90, 60, 1], to: destination, at: HostTime.now()))
      try await eventually { entered.withLock { $0 } }
      // Put a discovery-triggering announcement ahead of the last Stop, while delivery is
      // paused. Discovery will see the sender gone, but its already queued Stop still matters.
      let newcomer = try ALSAMIDI(name: tag + " Newcomer", connectsInputs: false)
      defer { newcomer.stop() }
      #expect(sender.send([0xFC], to: destination, at: HostTime.now()))
      sender.stop()
      release.signal()
      try await eventually { clocks.withLock { $0 == [.stop] } }
    }

    @Test func shutdownFromCallbackDoesNotDeadlock() async throws {
      let tag = "Driftbox Stop " + UUID().uuidString
      let sender = try ALSAMIDI(name: tag + " Sender", connectsInputs: false)
      let receiver = try ALSAMIDI(name: tag + " Receiver")
      defer {
        receiver.stop()
        sender.stop()
      }
      try await eventually { sender.destinations.contains(tag + " Receiver: Input") }
      let stopped = Mutex(false)
      receiver.onMessage = { [weak receiver] _ in
        receiver?.stop()
        stopped.withLock { $0 = true }
      }
      #expect(sender.send([0x90, 60, 1], to: .port(tag + " Receiver: Input"), at: HostTime.now()))
      try await eventually { stopped.withLock { $0 } }
      receiver.stop()
      #expect(receiver.sources.isEmpty)
    }
  }
#endif
