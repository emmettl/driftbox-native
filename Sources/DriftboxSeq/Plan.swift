// What one step of the arrangement plays. A port of `driftbox/packages/engine/src/schedule.ts`: a
// pure function of the song and a position, which reads nothing and schedules nothing.
//
// This is the faithful form, held to the reference's output exactly, and it builds arrays as it
// goes. It is not what the render thread will call. The real-time path plans from a song compiled
// ahead of time into indices and fixed storage, and this is what that gets checked against.

/// Where the transport is. `time` is straight — no swing — because swing is per voice.
public struct StepEvent: Equatable, Sendable {
  /// Steps since the transport started, never wrapping.
  public var absolute: Int
  /// Position within the current bar.
  public var index: Int
  /// Bars since the transport started.
  public var bar: Int
  public var time: Double
  public var stepSeconds: Double

  public init(absolute: Int, index: Int, bar: Int, time: Double, stepSeconds: Double) {
    self.absolute = absolute
    self.index = index
    self.bar = bar
    self.time = time
    self.stepSeconds = stepSeconds
  }
}

public struct DrumHit: Equatable, Sendable {
  public var voiceId: String
  public var time: Double
  /// 1 for an accent, 0.55 for a normal hit — the two velocities the grid has.
  public var accent: Double
  /// Knobs resolved at this exact song position.
  public var params: VoiceParams
  public var sends: SendLevels
}

public struct BassHit: Equatable, Sendable {
  public var voiceId: String
  public var time: Double
  public var note: BassNote
  public var sends: SendLevels
}

public struct StepPlan: Equatable, Sendable {
  public var time: Double
  public var stepSeconds: Double
  public var bpm: Double
  public var fx: FxParams
  /// Pattern-controlled filter strike for the song-wide insert.
  public var pcf: StepValue
  public var drums: [DrumHit]
  public var bass: [BassHit]
}

extension Song {
  /// One machine's pattern through a live clip launch, falling back to the authored section.
  func selectedPattern(bar: Int, slot: ClipSlot, selection: ClipSelection) -> Pattern? {
    if let id = selection[slot], !id.isEmpty, let launched = pattern(id: id) { return launched }
    return pattern(forBar: bar, slot: slot)
  }

  /// A launched polymetric clip may lengthen the incoming bar.
  public func barLength(forBar bar: Int, selection: ClipSelection) -> Int {
    var length = barLength(forBar: bar)
    for slot in ClipSlot.allCases {
      length = max(length, selectedPattern(bar: bar, slot: slot, selection: selection)?.length ?? 0)
    }
    return length
  }

  /// Everything one step plays, at absolute times. Swing is applied here, per voice: hats
  /// shuffling against a kick that stays on the grid is a groove one global setting cannot give.
  public func planStep(_ event: StepEvent, selection: ClipSelection = ClipSelection()) -> StepPlan {
    let bpm = bpm(bar: event.bar, index: event.index)
    let stepSeconds = 60 / bpm / 4
    let fx = fxParams(bar: event.bar, index: event.index)
    guard let pattern = pattern(forBar: event.bar) else {
      return StepPlan(
        time: event.time, stepSeconds: stepSeconds, bpm: bpm, fx: fx, pcf: .off, drums: [], bass: [])
    }

    func swung(_ voiceId: String) -> Double {
      event.time
        + swingDelay(
          step: event.index, swing: swing(voiceId, bar: event.bar, index: event.index),
          stepSeconds: stepSeconds)
    }

    // The whole-groove pattern and each machine's selection say which voice ids might exist;
    // each voice is then read from its own machine's clip. First appearance fixes the order.
    let selected = ClipSlot.allCases.map {
      selectedPattern(bar: event.bar, slot: $0, selection: selection)
    }
    var sources = [pattern]
    for case let source? in selected { sources.append(source) }

    func source(for voiceId: String) -> Pattern? {
      guard let slot = ClipSlot(voiceId: voiceId) else { return pattern }
      return selected[slot.rawValue]
    }

    var drumVoices: [String] = []
    var bassVoices: [String] = []
    for source in sources {
      for voiceId in source.tracks.keys where !drumVoices.contains(voiceId) {
        drumVoices.append(voiceId)
      }
      for voiceId in source.bass.keys where !bassVoices.contains(voiceId) {
        bassVoices.append(voiceId)
      }
    }

    var drums: [DrumHit] = []
    for voiceId in drumVoices {
      guard let source = source(for: voiceId) else { continue }
      let value = source.step(voiceId, at: event.index)
      if value == .off { continue }
      let time = swung(voiceId)
      let hit = DrumHit(
        voiceId: voiceId, time: time, accent: value == .accent ? 1 : 0.55,
        params: voiceParams(voiceId, bar: event.bar, index: event.index),
        sends: sendLevels(voiceId, bar: event.bar, index: event.index))
      drums.append(hit)
      if voiceId.hasPrefix("909."), source.flam(voiceId, at: event.index) {
        // The flam knob sets the gap between the two strikes, kept narrow enough to read as one
        // articulated hit rather than an echo.
        var second = hit
        second.time = time + (0.012 + (kit.flam ?? 0.4) * 0.048)
        drums.append(second)
      }
    }

    var bass: [BassHit] = []
    for voiceId in bassVoices {
      guard let source = source(for: voiceId), let line = source.bass[voiceId] else { continue }
      let at = event.index % source.length
      guard at >= 0, at < line.count else { continue }
      // Gate lengths are in seconds, so the note has to know how long a step currently is.
      let note = bassNote(
        params: bassParams(voiceId, bar: event.bar, index: event.index), step: line[at],
        previous: previousStep(line, index: event.index, length: source.length),
        stepSeconds: stepSeconds)
      if let note {
        bass.append(
          BassHit(
            voiceId: voiceId, time: swung(voiceId), note: note,
            sends: sendLevels(voiceId, bar: event.bar, index: event.index)))
      }
    }

    return StepPlan(
      time: event.time, stepSeconds: stepSeconds, bpm: bpm, fx: fx, pcf: pattern.pcf(at: event.index),
      drums: drums, bass: bass)
  }

  /// Every step of `bars` bars, in order, as if a transport had played it from the top — with
  /// `selection` launched throughout, if there is one.
  public func plan(
    bars: Int, from start: Double = 0, selection: ClipSelection = ClipSelection()
  ) -> [StepPlan] {
    var out: [StepPlan] = []
    var time = start
    for bar in 0..<max(0, bars) {
      for index in 0..<barLength(forBar: bar, selection: selection) {
        let stepSeconds = 60 / bpm(bar: bar, index: index) / 4
        out.append(
          planStep(
            StepEvent(absolute: out.count, index: index, bar: bar, time: time, stepSeconds: stepSeconds),
            selection: selection))
        time += stepSeconds
      }
    }
    return out
  }
}
