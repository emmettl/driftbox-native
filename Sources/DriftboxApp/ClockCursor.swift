#if canImport(AVFoundation)
  import DriftboxHost
  import DriftboxSeq

  /// The scheduling cursor behind the MIDI clock out: which step's ticks go out next, and when
  /// that step begins on the host clock.
  ///
  /// Held from pass to pass rather than worked out afresh each time: the transport's position only
  /// moves when a render block runs, so a reading of it is anything up to a block old, and deriving
  /// every timestamp from a fresh one would put that jitter into the clock — which is the thing
  /// stamping the messages was for. The cursor only moves forward, so no step's ticks go out
  /// twice, and each pass fills it up to the horizon, so none is missed however late the pass was.
  ///
  /// It decides and does not send: what goes out, and when, comes back as values, and putting them
  /// on a port is the player's business. That is also the whole of what a clock can be tested
  /// without, since nothing on the other end of a CoreMIDI port answers questions.
  struct ClockCursor {
    /// One thing to do to the port, in the order it was decided.
    enum Out: Equatable {
      /// Drop what is still queued: those ticks are for a bar that is no longer happening.
      case flush
      case send(ClockMessage, at: UInt64)
    }

    private struct Run {
      var step: Int
      var time: UInt64
    }

    private var run: Run?
    /// Stopped here, but the engine has not said so yet: it hears the stop on its next block and
    /// the pass reads that later still, and without this the clock would take the interval for a
    /// transport that is still running and start itself up again a moment after being stopped.
    private(set) var isHalted = false

    /// How far past the transport the ticks are written. Comfortably more than the thirtieth of a
    /// second between passes, so a pass that runs late still finds its steps unsent, and little
    /// enough that a seek throws away only a step or two of what was already queued.
    static let lookahead = 0.2
    /// A disagreement between the clock and the transport larger than this is a seek. Smaller than
    /// the shortest step there can be, so a jump of even one step is noticed.
    static let tolerance = 0.03
    /// And anything smaller is the two clocks parting — the audio device's and the host's are not
    /// the same crystal — which is pulled back a hair at a time. Fifty microseconds a step is a
    /// good half millisecond a second, far more than the drift, and far too little to hear.
    static let slew = 0.00005

    /// Whether anything is out there that would have to be stopped.
    var isRunning: Bool { run != nil }

    /// Everything to send for the steps that begin within the lookahead, having first located the
    /// clock if this is a start or the transport has moved out from under it.
    mutating func advance(timeline: Timeline, songTime: Double, now: UInt64, sounding: UInt64) -> [Out] {
      guard !isHalted, !timeline.times.isEmpty else { return [] }
      var out: [Out] = []
      var current: Run
      var correction = 0.0
      if let held = run, held.step < timeline.times.count,
        let drift = drift(held, timeline: timeline, songTime: songTime, sounding: sounding),
        abs(drift) <= Self.tolerance
      {
        current = held
        correction = drift
      } else {
        current = locate(
          step: timeline.step(at: songTime) ?? 0, timeline: timeline, songTime: songTime,
          sounding: sounding, into: &out)
      }

      while MIDIOutput.seconds(from: now, to: current.time) < Self.lookahead {
        // The drift is taken out a step at a time rather than all at once, so that no gap between
        // two ticks is off by more than the slew however long the two clocks have been apart.
        if correction != 0 {
          let nudge = min(Self.slew, abs(correction)) * (correction > 0 ? 1 : -1)
          current.time = MIDIOutput.time(current.time, after: nudge)
          correction -= nudge
        }
        let length = timeline.length(ofStep: current.step)
        for scheduled in scheduleClockStep(at: 0, stepSeconds: length) {
          out.append(.send(scheduled.message, at: MIDIOutput.time(current.time, after: scheduled.time)))
        }
        current.time = MIDIOutput.time(current.time, after: length)
        current.step += 1
        if current.step == timeline.times.count { current.step = 0 }
      }
      run = current
      return out
    }

    /// The transport is not running, or the clock is no longer ours to send. Whatever the engine
    /// was asked to do it has now done, so a start may be believed again.
    mutating func idle(at now: UInt64) -> [Out] {
      isHalted = false
      return stop(at: now)
    }

    /// Stopped at the transport, ahead of the engine reporting it.
    mutating func halt(at now: UInt64) -> [Out] {
      isHalted = true
      return stop(at: now)
    }

    /// Started at the transport, likewise: a halt the engine has not caught up with yet must not
    /// leave the clock held down.
    mutating func resume() {
      isHalted = false
    }

    /// Stop, and drop whatever was written ahead of it, so that nothing is left ticking behind the
    /// stop and running the other end on by itself.
    mutating func stop(at now: UInt64) -> [Out] {
      defer { run = nil }
      guard run != nil else { return [] }
      return [.flush, .send(.stop, at: now)]
    }

    /// How far ahead of the transport the clock has got, in seconds. The run says the song will be
    /// at the top of its step at its time, which is a reading of where the song is; the difference
    /// from where it actually is is nothing at all while the two run together. The song loops, so a
    /// difference of nearly a whole pass is the two of them either side of the top rather than a
    /// jump, and wraps to nothing.
    private func drift(_ run: Run, timeline: Timeline, songTime: Double, sounding: UInt64) -> Double? {
      guard timeline.end > 0 else { return nil }
      var drift = timeline.times[run.step] - MIDIOutput.seconds(from: sounding, to: run.time) - songTime
      drift = drift.truncatingRemainder(dividingBy: timeline.end)
      if drift > timeline.end / 2 { drift -= timeline.end }
      if drift < -timeline.end / 2 { drift += timeline.end }
      return drift
    }

    /// Say where the song is and start it there. Starting anywhere but the first step sends the
    /// position before the continue, which is what a device needs to play the right bar and not
    /// merely the right tempo. A clock that was already running is stopped first, and what it had
    /// queued dropped: those ticks are for a bar that is no longer happening.
    private func locate(
      step: Int, timeline: Timeline, songTime: Double, sounding: UInt64, into out: inout [Out]
    ) -> Run {
      if run != nil {
        out.append(.flush)
        out.append(.send(.stop, at: sounding))
      }
      for scheduled in scheduleClockStart(step: step, at: 0) {
        out.append(.send(scheduled.message, at: sounding))
      }
      // Ticking picks up at the next step to begin: the one the transport is already inside has had
      // some of its ticks go by, and sending them now would only bunch them at the start.
      var next = step
      if songTime - timeline.times[step] > 0.001 { next += 1 }
      if next >= timeline.times.count { next = 0 }
      return Run(
        step: next, time: time(ofStep: next, timeline: timeline, songTime: songTime, sounding: sounding))
    }

    /// When `step` begins on the host clock, given that the song is at `songTime` at `sounding`.
    private func time(ofStep step: Int, timeline: Timeline, songTime: Double, sounding: UInt64) -> UInt64 {
      var ahead = timeline.times[step] - songTime
      // Behind the transport means the step is the one coming round on the next pass.
      if ahead < 0 { ahead += timeline.end }
      return MIDIOutput.time(sounding, after: ahead)
    }
  }
#endif
