#if canImport(CoreMIDI)
  import CoreMIDI
  @testable import DriftboxHost
  import DriftboxSeq
  import Foundation
  import Testing

  /// The MIDI ends, which nothing else reaches: the encoding on its own, and then the whole way
  /// round — out through the virtual source and back in through the input, which is the only
  /// honest way to test either without a cable.
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
