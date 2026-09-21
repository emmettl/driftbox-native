// Reading a song: which pattern a bar plays, how long that bar is, what a step holds. A port of
// the reading half of `driftbox/packages/engine/src/pattern.ts`. The editing half — adding,
// rotating, randomising — arrives with the editor that needs it.

extension Pattern {
  /// The loop length of one drum voice. Never longer than the pattern.
  public func trackLength(_ voiceId: String) -> Int {
    guard let length = trackLengths[voiceId] else { return self.length }
    return max(1, min(self.length, length))
  }

  public func step(_ voiceId: String, at step: Int) -> StepValue {
    guard let track = tracks[voiceId] else { return .off }
    let index = wrap(step, trackLength(voiceId))
    return index < track.count ? track[index] : .off
  }

  public func flam(_ voiceId: String, at step: Int) -> Bool {
    guard let marks = flams[voiceId] else { return false }
    let index = wrap(step, trackLength(voiceId))
    return index < marks.count ? marks[index] : false
  }

  public func pcf(at step: Int) -> StepValue {
    guard let pcf else { return .off }
    let index = step % length
    return index >= 0 && index < pcf.count ? pcf[index] : .off
  }
}

extension Pattern {
  /// Off → on → accent → off, as the machines' step buttons go. A step that goes off loses its
  /// flam mark too.
  public func cyclingStep(_ voiceId: String, at step: Int) -> Pattern {
    let current = self.step(voiceId, at: step)
    let next: StepValue =
      switch current {
      case .off: .on
      case .on: .accent
      case .accent: .off
      }
    return settingStep(voiceId, at: step, to: next)
  }

  public func settingStep(_ voiceId: String, at step: Int, to value: StepValue) -> Pattern {
    var out = self
    var track = tracks[voiceId] ?? [StepValue](repeating: .off, count: length)
    if track.count < length { track += [StepValue](repeating: .off, count: length - track.count) }
    let index = wrap(step, trackLength(voiceId))
    track[index] = value
    out.tracks[voiceId] = track
    if value == .off, var marks = flams[voiceId] {
      if index < marks.count { marks[index] = false }
      out.flams[voiceId] = marks
    }
    return out
  }
}

extension Song {
  public func pattern(id: String) -> Pattern? {
    patterns.first { $0.id == id }
  }

  /// How long the whole song is, in bars, before it loops.
  public var bars: Int {
    chain.reduce(0) { $0 + max(1, $1.repeat) }
  }

  /// Which entry of the chain a bar falls in. Walked rather than expanded: a hundred-bar section
  /// is a reasonable thing to write, and this is asked on every bar line.
  public func chainStep(atBar bar: Int) -> ChainStep? {
    let total = bars
    guard total > 0 else { return nil }
    var remaining = wrap(bar, total)
    for step in chain {
      let `repeat` = max(1, step.repeat)
      if remaining < `repeat` { return step }
      remaining -= `repeat`
    }
    return nil
  }

  /// The whole-groove pattern for a bar. An empty chain, or an entry naming a pattern that is not
  /// here, falls back to the first pattern, so a song is never silent for want of an arrangement.
  public func pattern(forBar bar: Int) -> Pattern? {
    guard let first = patterns.first else { return nil }
    guard !chain.isEmpty, let step = chainStep(atBar: bar) else { return first }
    return pattern(id: step.pattern) ?? first
  }

  /// One machine's clip for a bar, falling back to the section's whole pattern.
  public func pattern(forBar bar: Int, slot: ClipSlot) -> Pattern? {
    guard let fallback = pattern(forBar: bar) else { return nil }
    guard !chain.isEmpty, let id = chainStep(atBar: bar)?.clips[slot], !id.isEmpty else {
      return fallback
    }
    return pattern(id: id) ?? fallback
  }

  /// A section lasts as long as its longest selected clip. Shorter clips wrap at their own length,
  /// so an 8-step 909 loops twice under a 16-step 303.
  public func barLength(forBar bar: Int) -> Int {
    guard let fallback = pattern(forBar: bar) else { return 16 }
    if chain.isEmpty { return fallback.length }
    var length = fallback.length
    for slot in ClipSlot.allCases {
      length = max(length, pattern(forBar: bar, slot: slot)?.length ?? 0)
    }
    return length
  }
}
