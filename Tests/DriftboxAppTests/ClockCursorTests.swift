#if canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq
  import Testing

  @testable import DriftboxApp

  /// The clock out, driven the way the tick drives it: the host clock and the transport moving on
  /// together thirty times a second, and the cursor asked each time what to send.
  struct ClockCursorTests {
    /// What the player takes off the host clock before stamping, so that the ticks land with the
    /// music rather than with the render block.
    static let latency = 0.01
    static let interval = 1.0 / 30

    struct Pass {
      var now: UInt64
      var messages: [ClockCursor.Out]
    }

    private func run(
      _ cursor: inout ClockCursor, timeline: Timeline, seconds: Double, from base: UInt64,
      startingAt songStart: Double = 0
    ) -> [Pass] {
      var passes: [Pass] = []
      var elapsed = 0.0
      while elapsed < seconds {
        let now = MIDIOutput.time(base, after: elapsed)
        let sounding = MIDIOutput.time(now, after: Self.latency)
        var songTime = songStart + elapsed
        if timeline.end > 0 { songTime = songTime.truncatingRemainder(dividingBy: timeline.end) }
        passes.append(
          Pass(
            now: now,
            messages: cursor.advance(
              timeline: timeline, songTime: songTime, now: now, sounding: sounding)))
        elapsed += Self.interval
      }
      return passes
    }

    private func tickTimes(_ messages: [ClockCursor.Out]) -> [UInt64] {
      messages.compactMap { message -> UInt64? in
        guard case .send(.tick, let at) = message else { return nil }
        return at
      }
    }

    /// Everything that is not a tick, in order, which is the whole of what a listening device is
    /// told about the transport.
    private func transport(_ messages: [ClockCursor.Out]) -> [ClockMessage] {
      messages.compactMap { message -> ClockMessage? in
        guard case .send(let clock, _) = message, clock != .tick else { return nil }
        return clock
      }
    }

    private func gaps(_ times: [UInt64]) -> [Double] {
      zip(times, times.dropFirst()).map { MIDIOutput.seconds(from: $0, to: $1) }
    }

    @Test func everyTickIsWrittenAheadOfThePassThatWroteIt() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let base = MIDIOutput.now()
      let passes = run(&cursor, timeline: timeline, seconds: 1, from: base)

      for pass in passes {
        for at in tickTimes(pass.messages) {
          let ahead = MIDIOutput.seconds(from: pass.now, to: at)
          #expect(ahead > 0)
          // Nothing is written further out than the horizon and the step it falls in.
          #expect(ahead < ClockCursor.lookahead + timeline.length(ofStep: 0))
        }
      }
    }

    @Test func noStepIsSentTwiceAndNoneIsMissed() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let passes = run(&cursor, timeline: timeline, seconds: 1, from: MIDIOutput.now())
      let times = passes.flatMap { tickTimes($0.messages) }

      // Twenty-four to the quarter, evenly: a tick sent twice would be a gap of nothing, and a step
      // gone missing would be a gap of seven. Whole steps went out, and between the first tick and
      // the last they cover the second that was run, so none of it was left out.
      let apart = timeline.length(ofStep: 0) / Double(ticksPerStep)
      #expect(times.count % ticksPerStep == 0)
      #expect(gaps(times).allSatisfy { abs($0 - apart) < 1e-5 })
      #expect(MIDIOutput.seconds(from: times[0], to: times[times.count - 1]) > 1)
    }

    /// A song that has come round to the top again is still the same run: the clock is a stream of
    /// ticks and a device following it loops on its own.
    @Test func aLoopWrapsWithoutAStopOrAPosition() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let passes = run(&cursor, timeline: timeline, seconds: 5, from: MIDIOutput.now())
      let messages = passes.flatMap(\.messages)

      #expect(transport(messages) == [.start])
      #expect(!messages.contains(.flush))
      let times = tickTimes(messages)
      // More than two passes of a two-second song went out, so the wrap is inside this.
      #expect(times.count > 2 * timeline.times.count * ticksPerStep)
      let apart = timeline.length(ofStep: 0) / Double(ticksPerStep)
      #expect(gaps(times).allSatisfy { abs($0 - apart) < 1e-5 })
    }

    @Test func aSeekStopsSaysWhereItIsAndContinues() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let base = MIDIOutput.now()
      _ = run(&cursor, timeline: timeline, seconds: 0.5, from: base)

      // Twelve steps on, which is a jump no two clocks could have drifted into.
      let now = MIDIOutput.time(base, after: 0.5)
      let sounding = MIDIOutput.time(now, after: Self.latency)
      let messages = cursor.advance(timeline: timeline, songTime: 1.5, now: now, sounding: sounding)
      #expect(
        Array(messages.prefix(4)) == [
          .flush, .send(.stop, at: sounding), .send(.position(step: 12), at: sounding),
          .send(.continue, at: sounding),
        ])
      #expect(transport(Array(messages.dropFirst(4))).isEmpty)
      // The ticks pick up at the step the position named, not wherever the old run had got to.
      #expect(tickTimes(messages).first == sounding)
    }

    /// A seek to the top says start rather than position and continue, which is the one place a
    /// device needs no locating.
    @Test func aSeekToTheTopStartsFromTheTop() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let base = MIDIOutput.now()
      _ = run(&cursor, timeline: timeline, seconds: 0.5, from: base)

      let now = MIDIOutput.time(base, after: 0.5)
      let sounding = MIDIOutput.time(now, after: Self.latency)
      let messages = cursor.advance(timeline: timeline, songTime: 0, now: now, sounding: sounding)
      #expect(transport(messages) == [.stop, .start])
      #expect(messages.first == .flush)
    }

    /// The audio device's clock and the host's are not the same crystal. A small disagreement is
    /// pulled back a hair at a time rather than relocating the whole run.
    @Test func aSmallDisagreementIsSlewedRatherThanRelocated() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let base = MIDIOutput.now()
      _ = run(&cursor, timeline: timeline, seconds: 0.5, from: base)

      let now = MIDIOutput.time(base, after: 0.5)
      let sounding = MIDIOutput.time(now, after: Self.latency)
      let messages = cursor.advance(timeline: timeline, songTime: 0.52, now: now, sounding: sounding)
      #expect(transport(messages).isEmpty)
      #expect(!messages.contains(.flush))
      let apart = timeline.length(ofStep: 0) / Double(ticksPerStep)
      #expect(gaps(tickTimes(messages)).allSatisfy { abs($0 - apart) <= ClockCursor.slew + 1e-5 })
    }

    @Test func stoppingSendsStopAndDropsWhatWasQueuedBehindIt() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let base = MIDIOutput.now()
      _ = run(&cursor, timeline: timeline, seconds: 0.2, from: base)
      #expect(cursor.isRunning)

      let now = MIDIOutput.time(base, after: 0.2)
      let sounding = MIDIOutput.time(now, after: Self.latency)
      #expect(cursor.halt(at: now) == [.flush, .send(.stop, at: now)])
      #expect(cursor.isHalted)
      #expect(!cursor.isRunning)
      // Nothing more goes out until the engine has caught up with the stop it was handed, or the
      // clock would start itself again a moment after being stopped.
      #expect(cursor.advance(timeline: timeline, songTime: 0.2, now: now, sounding: sounding).isEmpty)
      // A second stop has nothing left to say.
      #expect(cursor.stop(at: now).isEmpty)
    }

    @Test func aTransportThatHasCaughtUpMayStartAgain() {
      let timeline = Timeline(song: steadySong())
      var cursor = ClockCursor()
      let now = MIDIOutput.now()
      let sounding = MIDIOutput.time(now, after: Self.latency)
      _ = cursor.halt(at: now)
      #expect(cursor.idle(at: now).isEmpty)
      #expect(!cursor.isHalted)
      #expect(
        transport(cursor.advance(timeline: timeline, songTime: 0, now: now, sounding: sounding)) == [.start])

      // And a start at the transport clears a halt the engine has not reported yet.
      _ = cursor.halt(at: now)
      cursor.resume()
      #expect(!cursor.isHalted)
    }

    @Test func aSongWithNoStepsHasNoClock() {
      var cursor = ClockCursor()
      let now = MIDIOutput.now()
      #expect(cursor.advance(timeline: Timeline(), songTime: 0, now: now, sounding: now).isEmpty)
      #expect(!cursor.isRunning)
    }
  }
#endif
