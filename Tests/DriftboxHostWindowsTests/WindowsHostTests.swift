#if os(Windows)
  import DriftboxHost
  import DriftboxSeq
  @testable import DriftboxHostWindows
  import Foundation
  import Synchronization
  import Testing

  /// Counts what a device renders from it, and renders a constant, so a test can tell both that a
  /// stream is calling it and what reaches the mix.
  final class Counter: @unchecked Sendable {
    let frames = Atomic<Int>(0)
    let level: Float
    init(level: Float = 0) { self.level = level }

    var source: RenderSource {
      RenderSource(
        context: Unmanaged.passUnretained(self).toOpaque(),
        render: { context, frames, left, right in
          Unmanaged<Counter>.fromOpaque(context)._withUnsafeGuaranteedRef { counter in
            counter.frames.add(frames, ordering: .relaxed)
            left.update(repeating: counter.level, count: frames)
            right.update(repeating: -counter.level, count: frames)
          }
        },
        sampleRate: 48000, owner: self)
    }
  }

  /// Against whatever this machine has. A machine with no audio device at all — a CI runner — has
  /// nothing to play through, which the route says rather than failing.
  @MainActor
  struct WASAPIRouteTests {
    @Test func theSystemsDeviceIsListedAndPlayedThrough() {
      let route = WASAPIRoute()
      guard let system = route.systemDefault else {
        #expect(route.current == nil && route.error != nil)
        return
      }
      #expect(route.devices.contains(system))
      #expect(route.current == system)
      #expect(route.error == nil)
      #expect(route.latency > 0 && route.latency < 0.5)
    }

    /// Attached, a source is rendered at the device's pace — about the engine's rate — and
    /// detached, it is not rendered again.
    @Test func anAttachedSourceIsRenderedInRealTime() {
      let route = WASAPIRoute()
      guard route.current != nil else { return }
      let counter = Counter()
      route.attach(counter.source)
      let began = Date()
      RunLoop.main.run(until: began.addingTimeInterval(0.5))
      let seconds = Date().timeIntervalSince(began)
      let rendered = Double(counter.frames.load(ordering: .relaxed)) / 48000
      // Within a period or two of the time that passed, plus the buffer filled ahead.
      #expect(abs(rendered - seconds) < 0.1, "rendered \(rendered)s in \(seconds)s")
      route.detach(counter.source.context)
      let after = counter.frames.load(ordering: .relaxed)
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      #expect(counter.frames.load(ordering: .relaxed) == after)
    }

    /// Choosing a device that is not there plays through the system's, and remembers the choice.
    @Test func aChoiceThatIsNotThereFallsBackToTheSystems() {
      let route = WASAPIRoute(chosen: "not a device")
      guard let system = route.systemDefault else { return }
      #expect(route.current == system)
      #expect(route.chosen == "not a device")
    }
  }

  struct MIDISchedulerTests {
    final class Sink: @unchecked Sendable {
      let arrived = Mutex<[(String, UInt32, UInt64)]>([])
    }

    /// Messages go out in the order of their stamps, each within a couple of milliseconds of it,
    /// however they were handed in.
    @Test func messagesGoOutWhenTheyAreStamped() async throws {
      let sink = Sink()
      let scheduler = MIDIScheduler { name, message in
        sink.arrived.withLock { $0.append((name, message, HostTime.now())) }
      }
      let now = HostTime.now()
      let offsets = [0.030, 0.010, 0.050, 0.020, 0.040]
      for (index, offset) in offsets.enumerated() {
        scheduler.schedule(UInt32(index), to: "out", at: HostTime.time(now, after: offset))
      }
      try await Task.sleep(for: .milliseconds(150))
      let arrived = sink.arrived.withLock { $0 }
      #expect(arrived.map(\.1) == [1, 3, 0, 4, 2])
      for (_, message, time) in arrived {
        let late = HostTime.seconds(from: HostTime.time(now, after: offsets[Int(message)]), to: time)
        // Within a few milliseconds: far inside the 15.6ms an ordinary timer would be out by, with
        // room for a shared machine that is busy.
        #expect(late >= -0.0005 && late < 0.005, "message \(message) \(late * 1000)ms late")
      }
      withExtendedLifetime(scheduler) {}
    }

    /// Letting go of the scheduler ends its thread: what was still waiting never goes.
    @Test func aSchedulerLetGoOfSendsNothingMore() async throws {
      let sink = Sink()
      do {
        let scheduler = MIDIScheduler { name, message in
          sink.arrived.withLock { $0.append((name, message, HostTime.now())) }
        }
        scheduler.schedule(1, to: "out", at: HostTime.time(HostTime.now(), after: 0.05))
      }
      try await Task.sleep(for: .milliseconds(100))
      #expect(sink.arrived.withLock { $0.isEmpty })
    }

    @Test func aFlushDropsWhatHasNotGone() async throws {
      let sink = Sink()
      let scheduler = MIDIScheduler { name, message in
        sink.arrived.withLock { $0.append((name, message, HostTime.now())) }
      }
      let later = HostTime.time(HostTime.now(), after: 0.05)
      scheduler.schedule(1, to: "a", at: later)
      scheduler.schedule(2, to: "b", at: later)
      scheduler.drop("a")
      try await Task.sleep(for: .milliseconds(100))
      #expect(sink.arrived.withLock { $0.map(\.0) } == ["b"])
      withExtendedLifetime(scheduler) {}
    }
  }

  struct WinMMTests {
    @Test func shortMessagesArePackedLowByteFirst() {
      #expect(WinMMOutput.packed([0xF8]) == 0xF8)
      #expect(WinMMOutput.packed([0x90, 60, 127]) == 0x7F_3C90)
      #expect(WinMMOutput.packed([0xF2, 0x10, 0x01]) == 0x01_10F2)
      #expect(WinMMOutput.packed([0xF0, 1, 2]) == nil)
      #expect(WinMMOutput.packed([0x40]) == nil)
    }

    /// What goes out packed comes back in as the bytes it was.
    @Test func shortMessagesUnpackAsTheyWerePacked() throws {
      for bytes: [UInt8] in [[0x90, 60, 127], [0xB3, 7, 100], [0xE0, 0, 64], [0xF8, 0, 0]] {
        #expect(WinMMInput.bytes(try #require(WinMMOutput.packed(bytes))) == bytes)
      }
    }

    @Test func thereIsNoVirtualSource() {
      let out = WinMMOutput()
      #expect(!out.offersVirtualSource)
      #expect(!out.send([0xF8], to: .virtual, at: HostTime.now()))
      #expect(!out.send([0xF8], to: .port("no such device"), at: HostTime.now()))
    }

    /// Through a loopback port, where the machine has one: Windows MIDI Services makes a pair, and
    /// what goes out of one comes in at the other. Skipped where there is none.
    @Test func clockSentThroughALoopbackArrivesBack() async throws {
      let out = WinMMOutput()
      let input = WinMMInput()
      guard let a = out.destinations.first(where: { $0.contains("Loopback") && $0.contains("A") }),
        input.sources.contains(where: { $0.contains("Loopback") && $0.contains("B") })
      else { return }
      let heard = Mutex<[ClockMessage]>([])
      input.onClock = { message, _ in heard.withLock { $0.append(message) } }
      let now = HostTime.now()
      out.send([0xFA], to: .port(a), at: now)
      out.send([0xF8], to: .port(a), at: HostTime.time(now, after: 0.01))
      out.send([0xFC], to: .port(a), at: HostTime.time(now, after: 0.02))
      try await Task.sleep(for: .milliseconds(200))
      #expect(heard.withLock { $0 } == [.start, .tick, .stop])
    }
  }
#endif
