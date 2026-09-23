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
  /// What must be so is a PASS or a FAIL: that everything comes back as it was sent, that a
  /// clock written ahead is heard when it is due, which only `AMidiOutput`'s scheduler makes so
  /// for a device that is another app, and that a flush drops what has not gone. How each stamp and
  /// arrival fell against its moment is written down beside them. "Heard" includes the input's
  /// polling, up to a millisecond.
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
      var early: [Double] = []
      for (clock, sent) in zip(clocks, ahead) {
        let due = base + sent.seconds * 1000
        early.append(clock.arrived - due)
        lines.append(
          "  \(sent.message): stamped \(fixed(clock.stamp - due))ms from when it was due, "
            + "heard \(fixed(clock.arrived - due))ms from it")
      }
      // Not early, which without the scheduler it is by a tenth of a second; and not so late that
      // it is anything but the loopback's own hop, which is another app's in use and not ours.
      check(
        clocks.count == ahead.count && early.allSatisfy { $0 > -1 && $0 < 20 },
        "a clock written ahead is heard when it is due, not when it was sent")
      lines.append(
        "  the scheduler's thread \(output.scheduledUrgently ? "has" : "did not get") urgent audio priority")

      // A clock as `ClockCursor` keeps one going: 24 ticks a beat at 120, each written ahead.
      heard.clocks.withLock { $0 = [] }
      _ = output.takeLateness()
      let start = HostTime.now()
      let spacing = 60.0 / 120 / 24
      for index in 0..<24 {
        output.send([0xF8], to: to, at: HostTime.time(start, after: 0.05 + Double(index) * spacing))
      }
      pause(0.05 + 24 * spacing + 0.2)
      let beat = heard.clocks.withLock { $0 }
      let startMilliseconds = Double(start) / HostTime.ticksPerSecond * 1000
      let lateness = beat.enumerated().map { index, clock in
        clock.arrived - (startMilliseconds + (0.05 + Double(index) * spacing) * 1000)
      }
      // What is Driftbox's to answer for is when each tick went out, and how evenly: a steady
      // lateness is a constant a clock follower takes up, a jumping one a wobble in the tempo.
      let sending = output.takeLateness()
      check(
        beat.count == 24 && sending.count == 24 && sending.most < 4 && sending.most - sending.least < 3,
        "a beat of clock goes out tick by tick on time: \(sending.count) of 24 sent, "
          + "\(fixed(sending.least)) to \(fixed(sending.most))ms after each was due, "
          + "\(fixed(sending.average))ms on average")
      if let least = lateness.min(), let most = lateness.max() {
        let mean = lateness.reduce(0, +) / Double(lateness.count)
        lines.append(
          "  and was heard back \(fixed(least)) to \(fixed(most))ms after, \(fixed(mean))ms on average, "
            + "through the loopback's own thread")
      }

      // A flush: ticks a third of a second ahead, flushed at once.
      heard.clocks.withLock { $0 = [] }
      let later = HostTime.now()
      for index in 0..<3 {
        output.send([0xF8], to: to, at: HostTime.time(later, after: 0.3 + Double(index) * 0.01))
      }
      output.flush(to)
      pause(0.6)
      let flushed = heard.clocks.withLock { $0.count }
      check(flushed == 0, "a flush drops what has not gone: \(flushed) of 3 came back after it")
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
