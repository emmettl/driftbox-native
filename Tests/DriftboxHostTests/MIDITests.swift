#if canImport(CoreMIDI)
  import CoreMIDI
  @testable import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  /// The MIDI ends, which nothing else reaches: the encoding on its own, and then the whole way
  /// round — out through the virtual source and back in through the input, which is the only
  /// honest way to test either without a cable. One at a time, because every test here talks to
  /// the one MIDI server on the machine and publishes a source under the same name.
  @Suite(.serialized)
  struct MIDITests {
    @Test func everyClockMessageBecomesTheRightPacket() throws {
      // One 32-bit word: the message type in the top nibble, then the status byte and its two
      // data bytes. Real time and system common are type 1, and a single-byte message pads.
      let tick = try #require(MIDIOutput.words(for: ClockMessage.tick.bytes))
      #expect(tick == [0x10F8_0000])
      let stop = try #require(MIDIOutput.words(for: ClockMessage.stop.bytes))
      #expect(stop == [0x10FC_0000])
      // Song position is three bytes, so both data bytes land: 129 steps is 1 and 1.
      let position = try #require(MIDIOutput.words(for: ClockMessage.position(step: 129).bytes))
      #expect(position == [0x10F2_0101])
      // Anything with a channel in it is type 2 instead.
      let note = try #require(MIDIOutput.words(for: [0x90, 60, 100]))
      #expect(note == [0x2090_3C64])
    }

    @Test func itRefusesWhatWillNotFitOneMessage() {
      #expect(MIDIOutput.words(for: []) == nil)
      // System exclusive, which needs more than one packet: a half-written stream would be
      // worse than none, and the clock has no use for it.
      #expect(MIDIOutput.words(for: [0xF0, 0x7E, 0xF7]) == nil)
      // And a data byte where a status byte should be.
      #expect(MIDIOutput.words(for: [0x40, 0x00]) == nil)
    }

    /// The host clock is not nanoseconds on every machine, which is the whole reason these are
    /// functions rather than arithmetic at the call site.
    @Test func hostTimeRoundTrips() {
      let base = MIDIOutput.now()
      for seconds in [0.0, 0.0005, 0.2, 1.5, 30.0] {
        let later = MIDIOutput.time(base, after: seconds)
        #expect(abs(MIDIOutput.seconds(from: base, to: later) - seconds) < 1e-6, "\(seconds)")
      }
      // And backwards, for a stamp that has already passed.
      let earlier = MIDIOutput.time(base, after: -0.1)
      #expect(MIDIOutput.seconds(from: base, to: earlier) < 0)
    }

    /// Out of the virtual source and back in through the input. This is the only test that
    /// touches the MIDI server at all, so it is also the only thing that says the client, the
    /// port and the source were really made.
    @Test func clockSentOnTheVirtualSourceArrivesBack() async throws {
      let output = MIDIOutput()
      let input = MIDIInput()
      let received = Received()
      input.onClock = { message, _ in received.add(message) }
      // The input connects to whatever sources exist when it is made and when the setup
      // changes; the source published above is one of them, but the notification is not
      // instant.
      try await Task.sleep(for: .milliseconds(400))

      let sent: [ClockMessage] = [.position(step: 129), .continue, .tick, .tick, .stop]
      let now = MIDIOutput.now()
      for (index, message) in sent.enumerated() {
        // Spread them slightly: several messages stamped identically may arrive in any order,
        // and the order is the thing being checked.
        let at = MIDIOutput.time(now, after: 0.01 + Double(index) * 0.005)
        #expect(output.send(message.bytes, to: .virtual, at: at), "\(message)")
      }
      try await Task.sleep(for: .milliseconds(600))

      let got = received.all()
      // A machine with other MIDI traffic could deliver more than was sent, so this asks that
      // what went out is in what came back, in order, rather than that nothing else is.
      #expect(got.count >= sent.count, "got \(got)")
      var remaining = got[...]
      for message in sent {
        guard let at = remaining.firstIndex(of: message) else {
          Issue.record("\(message) never arrived; got \(got)")
          return
        }
        remaining = remaining[(at + 1)...]
      }
    }

    /// A source that has been ignored delivers nothing, and the same source heard again
    /// delivers. By name, which is how it is stored, through the real server, which is the
    /// only place the tag that says where a message came from is ever written.
    @Test func anIgnoredSourceIsNotHeard() async throws {
      let input = MIDIInput()
      let announced = Announced()
      input.onSourcesChange = { names in announced.set(names) }
      // Made after the input, so it arrives as a change rather than as part of the first list.
      let output = MIDIOutput()
      let received = Received()
      input.onClock = { message, _ in received.add(message) }
      try await Task.sleep(for: .milliseconds(400))
      let name = try #require(announced.names?.first { $0.contains("Driftbox Clock") })
      #expect(input.sources.contains(name))

      input.ignoring = [name]
      #expect(output.send(ClockMessage.stop.bytes, to: .virtual, at: MIDIOutput.now()))
      try await Task.sleep(for: .milliseconds(300))
      #expect(!received.all().contains(.stop), "ignored, so nothing")

      input.ignoring = []
      #expect(output.send(ClockMessage.stop.bytes, to: .virtual, at: MIDIOutput.now()))
      try await Task.sleep(for: .milliseconds(300))
      #expect(received.all().contains(.stop), "heard again")
    }

    /// A hidden source is not there at all: not listed, and not heard. This is how the app's
    /// own output is kept out of its own input, by ID rather than by name, because another copy
    /// of Driftbox has a source with the same name and is a perfectly good thing to follow.
    @Test func aHiddenSourceIsNeitherListedNorHeard() async throws {
      let output = MIDIOutput()
      let input = MIDIInput()
      let received = Received()
      input.onClock = { message, _ in received.add(message) }
      try await Task.sleep(for: .milliseconds(300))
      let id = try #require(output.sourceID)
      let before = input.sources.filter { $0.contains("Driftbox Clock") }.count
      #expect(before >= 1)

      input.hiding = [id]
      #expect(input.sources.filter { $0.contains("Driftbox Clock") }.count == before - 1)
      #expect(output.send(ClockMessage.stop.bytes, to: .virtual, at: MIDIOutput.now()))
      try await Task.sleep(for: .milliseconds(300))
      #expect(!received.all().contains(.stop))

      input.hiding = []
      #expect(input.sources.filter { $0.contains("Driftbox Clock") }.count == before)
      #expect(output.send(ClockMessage.stop.bytes, to: .virtual, at: MIDIOutput.now()))
      try await Task.sleep(for: .milliseconds(300))
      #expect(received.all().contains(.stop))
    }

    final class Announced: @unchecked Sendable {
      private var latest: [String]?
      private let lock = NSLock()

      func set(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        latest = names
      }

      var names: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return latest
      }
    }

    /// The callback arrives on the MIDI server's own thread, so what it writes into needs a
    /// lock rather than an array.
    final class Received: @unchecked Sendable {
      private var messages: [ClockMessage] = []
      private let lock = NSLock()

      func add(_ message: ClockMessage) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
      }

      func all() -> [ClockMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
      }
    }
  }
#endif
