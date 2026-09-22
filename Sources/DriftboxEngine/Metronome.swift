// The click. A port of `driftbox/packages/engine/src/metronome.ts`.
//
// Described as a `VoiceSpec` like everything else, so it goes through the same renderer as the
// drums — but it is not a voice. It has no knobs, it is not in the kit, it never appears in a
// pattern, and it does not go through the bus: `SongEngine` adds it after the master, so the
// pad sweeping the filter shut cannot take the count-in with it.

/// A short wooden tick: two square partials that beat against each other just enough to cut
/// through, and a scrape of high noise on the transient so it never sounds like part of the
/// music. `strong` marks the first beat of the bar, higher and a touch louder. The gains are
/// the reference's, set there from rendered peaks — strong 0.70, weak 0.50 — so the bar is
/// obvious and the click, which bypasses the bus compressor, never clips.
public func metronomeClick(strong: Bool) -> VoiceSpec {
  let base = strong ? 1600.0 : 1050.0
  let decay = 0.035
  func partial(_ frequency: Double, _ gain: Double) -> Source {
    Source(
      .oscillator(Oscillator(type: .square, frequency: frequency)), gain: gain,
      amp: [Breakpoint(to: 1, at: 0.0008, curve: .linear), Breakpoint(to: 0, at: decay)])
  }
  return VoiceSpec(
    duration: decay + 0.02,
    sources: [
      partial(base, 0.6),
      partial(base * 1.47, 0.4),
      Source(
        .noise(Noise()), gain: 0.35,
        amp: [Breakpoint(to: 1, at: 0.0004, curve: .linear), Breakpoint(to: 0, at: 0.008)],
        filter: FilterSpec(type: .highpass, frequency: 4000)),
    ],
    filter: FilterSpec(type: .bandpass, frequency: base, q: 1.1),
    gain: strong ? 0.376 : 0.25)
}
