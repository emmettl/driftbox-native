#if os(Android)
  import Android
  import DriftboxHost
  import DriftboxHostAndroid
  import DriftboxSeq
  import Synchronization

  /// The MIDI ports, tested against Driftbox Loopback: the app's own MIDI device, which sends back
  /// what it is sent, stamp and all. Nothing needs plugging in, as with the loopback port the
  /// Windows tests use.
  ///
  /// What must be so is a PASS or a FAIL. What is only measured — how a stamp and an arrival fall
  /// against the moment a message was due — is written down, since that is what says whether
  /// anything between here and a device holds a message to its time.
  enum MIDILoopback {
    static let name = "Driftbox Loopback"

    /// What came back, from the input's thread.
    final class Heard: Sendable {
      struct Clock: Sendable {
        var message: ClockMessage
        /// Milliseconds on `HostTime`'s clock: the stamp it came with, and when it was heard.
        var stamp: Double
        var arrived: Double
      }

      let messages = Mutex<[[UInt8]]>([])
      let notes = Mutex<[Int]>([])
      let velocities = Mutex<[Double]>([])
      let clocks = Mutex<[Clock]>([])
    }

    static func run(devices: AMidiDevices) -> String {
      var lines: [String] = []
      func check(_ passed: Bool, _ what: String) { lines.append("\(passed ? "PASS" : "FAIL") \(what)") }

      let input = AMidiInput(devices: devices)
      let output = AMidiOutput(devices: devices)
      lines.append("sources: \(input.sources)")
      lines.append("destinations: \(output.destinations)")
      guard input.sources.contains(name), output.destinations.contains(name) else {
        check(false, "\(name) is a source and a destination")
        return lines.joined(separator: "\n")
      }
      let heard = Heard()
      input.onMessage = { bytes in heard.messages.withLock { $0.append(bytes) } }
      input.onNote = { note, velocity in
        heard.notes.withLock { $0.append(note) }
        heard.velocities.withLock { $0.append(velocity) }
      }
      input.onClock = { message, stamp in
        let clock = Heard.Clock(message: message, stamp: stamp, arrived: HostTime.milliseconds())
        heard.clocks.withLock { $0.append(clock) }
      }
      let to = MIDIDestination.port(name)

      // Notes: one to a packet, two in one packet under running status, and system exclusive
      // between them, which is not a note and must not end up in one.
      let now = HostTime.now()
      output.send([0x90, 60, 100], to: to, at: now)
      output.send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], to: to, at: now)
      output.send([0x90, 62, 90, 64, 80], to: to, at: now)
      // A clock written ahead of time, as `ClockCursor` writes one.
      let ahead: [(message: ClockMessage, seconds: Double)] = [
        (.start, 0.100), (.tick, 0.110), (.tick, 0.120), (.tick, 0.130), (.position(step: 0x110), 0.140),
      ]
      for (message, seconds) in ahead {
        output.send(message.bytes, to: to, at: HostTime.time(now, after: seconds))
      }
      pause(0.5)

      let messages = heard.messages.withLock { $0 }
      check(
        messages == [[0x90, 60, 100], [0x90, 62, 90], [0x90, 64, 80]],
        "notes come back whole, running status filled in, system exclusive skipped: \(messages)")
      let notes = heard.notes.withLock { $0 }
      let velocities = heard.velocities.withLock { $0 }
      check(
        notes == [60, 62, 64] && velocities.first.map { abs($0 - 100.0 / 127) < 1e-9 } == true,
        "notes reach onNote: \(notes)")
      let clocks = heard.clocks.withLock { $0 }
      check(
        clocks.map(\.message) == ahead.map(\.message),
        "the clock comes back in order: \(clocks.map { "\($0.message)" }.joined(separator: ", "))")
      let base = Double(now) / HostTime.ticksPerSecond * 1000
      for (clock, sent) in zip(clocks, ahead) {
        let due = base + sent.seconds * 1000
        lines.append(
          "  \(sent.message): stamped \(fixed(clock.stamp - due))ms from when it was due, "
            + "heard \(fixed(clock.arrived - due))ms from it")
      }

      // A flush: ticks a third of a second ahead, flushed at once.
      heard.clocks.withLock { $0 = [] }
      let later = HostTime.now()
      for index in 0..<3 {
        output.send([0xF8], to: to, at: HostTime.time(later, after: 0.3 + Double(index) * 0.01))
      }
      output.flush(to)
      pause(0.6)
      lines.append("  flush: \(heard.clocks.withLock { $0.count }) of 3 ticks sent ahead came back after it")
      return lines.joined(separator: "\n")
    }

    private static func pause(_ seconds: Double) {
      var interval = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - Double(Int(seconds))) * 1e9))
      nanosleep(&interval, nil)
    }

    /// Tenths of a millisecond, signed.
    private static func fixed(_ milliseconds: Double) -> String {
      let tenths = Int((milliseconds * 10).rounded())
      return "\(tenths < 0 ? "-" : "+")\(abs(tenths) / 10).\(abs(tenths) % 10)"
    }
  }
#endif
