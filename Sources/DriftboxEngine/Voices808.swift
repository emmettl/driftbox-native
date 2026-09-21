import DriftboxSeq

// The TR-808, as data. A port of `driftbox/packages/engine/src/voices/tr808.ts`, where the
// reasoning for each number lives. Held to it exactly by `conformance/fixtures/voices`.

private func bassDrum(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let base = range(params.tune, 42, 72)
  let decay = ratioRange(params.decay, 0.12, 1.6)
  // The pitch drop is fast and fairly subtle: a ringing circuit settling, not a swoop.
  let attack = base * range(params.tone, 2.2, 4.4)

  return VoiceSpec(
    duration: decay + 0.1,
    sources: [
      Source(
        .oscillator(Oscillator(type: .sine, frequency: attack, pitch: [Breakpoint(to: base, at: 0.042)])),
        gain: 1, amp: strike(attack: 0.002, decay: decay)),
      // The click: the trigger pulse bleeding through, and most of what lets a kick cut through.
      Source(
        .noise(Noise()), gain: range(params.colour, 0, 0.5), amp: strike(attack: 0.0004, decay: 0.014),
        filter: FilterSpec(type: .highpass, frequency: 1200)),
    ],
    gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
}

private func snare(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let tune = ratioRange(params.tune, 0.75, 1.35)
  let snappy = range(params.colour, 0.05, 1)
  let noiseDecay = ratioRange(params.decay, 0.05, 0.4)
  let toneDecay = min(noiseDecay, 0.12)

  func body(_ frequency: Double, _ gain: Double) -> Source {
    Source(
      .oscillator(Oscillator(type: .triangle, frequency: frequency * tune)), gain: gain,
      amp: strike(attack: 0.001, decay: toneDecay))
  }

  return VoiceSpec(
    duration: max(noiseDecay, toneDecay) + 0.05,
    sources: [
      // Two tuned shells, a fifth-ish apart, are the body; the noise on top is the wires.
      body(185, (1 - snappy * 0.5) * 0.9),
      body(330, (1 - snappy * 0.5) * 0.5),
      Source(
        .noise(Noise()), gain: snappy, amp: strike(attack: 0.001, decay: noiseDecay),
        filter: FilterSpec(type: .highpass, frequency: range(params.tone, 700, 2600))),
    ],
    gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
}

private func clap(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let decay = ratioRange(params.decay, 0.12, 0.6)
  let centre = range(params.tone, 700, 1800)
  // Three fast retriggers and then a tail. That stutter is why it sounds like several hands.
  let spacing = range(params.colour, 0.006, 0.016)

  func burst(_ delay: Double, _ gain: Double) -> Source {
    Source(.noise(Noise()), gain: gain, amp: strike(attack: 0.0006, decay: 0.012), delay: delay)
  }

  return VoiceSpec(
    duration: decay + spacing * 3 + 0.05,
    sources: [
      burst(0, 0.8),
      burst(spacing, 0.9),
      burst(spacing * 2, 1),
      Source(.noise(Noise()), gain: 0.7, amp: strike(attack: 0.001, decay: decay), delay: spacing * 3),
    ],
    filter: FilterSpec(type: .bandpass, frequency: centre, q: 1.6),
    gain: accentGain(params, accent) * 0.9, pan: range(params.pan, -1, 1))
}

/// Hats and cymbals differ only in filtering and ring time.
private func metallic(
  decay decayRange: (Double, Double), bandpass: Double, q: Double
) -> @Sendable (VoiceParams, Double) -> VoiceSpec {
  { params, accent in
    let base = 40 * ratioRange(params.tune, 0.7, 1.5)
    let decay = ratioRange(params.decay, decayRange.0, decayRange.1)
    let bright = ratioRange(params.tone, 0.6, 1.7)

    return VoiceSpec(
      duration: decay + 0.05,
      sources: metallicSources(base: base, gain: 0.35, amp: strike(attack: 0.0008, decay: decay)),
      filter: FilterSpec(type: .bandpass, frequency: bandpass * bright, q: q),
      gain: accentGain(params, accent) * 0.5, pan: range(params.pan, -1, 1))
  }
}

private func tom(_ low: Double, _ high: Double) -> @Sendable (VoiceParams, Double) -> VoiceSpec {
  { params, accent in
    let base = range(params.tune, low, high)
    let decay = ratioRange(params.decay, 0.1, 0.7)

    return VoiceSpec(
      duration: decay + 0.05,
      sources: [
        Source(
          .oscillator(
            Oscillator(type: .sine, frequency: base * 1.9, pitch: [Breakpoint(to: base, at: 0.06)])),
          gain: 1, amp: strike(attack: 0.002, decay: decay)),
        Source(
          .noise(Noise()), gain: range(params.colour, 0, 0.22), amp: strike(attack: 0.001, decay: 0.03),
          filter: FilterSpec(type: .highpass, frequency: 600)),
      ],
      gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
  }
}

private func cowbell(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let tune = ratioRange(params.tune, 0.8, 1.25)
  let decay = ratioRange(params.decay, 0.1, 0.6)
  let amp = strike(attack: 0.001, decay: decay)

  // Two squares a slightly-off interval apart, band-limited hard. Famous for it.
  return VoiceSpec(
    duration: decay + 0.05,
    sources: [
      Source(.oscillator(Oscillator(type: .square, frequency: 540 * tune)), gain: 0.6, amp: amp),
      Source(.oscillator(Oscillator(type: .square, frequency: 800 * tune)), gain: 0.6, amp: amp),
    ],
    filter: FilterSpec(type: .bandpass, frequency: range(params.tone, 1800, 3600), q: 2.4),
    gain: accentGain(params, accent) * 0.7, pan: range(params.pan, -1, 1))
}

private func rimshot(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let decay = ratioRange(params.decay, 0.02, 0.09)
  return VoiceSpec(
    duration: decay + 0.03,
    sources: [
      Source(
        .oscillator(
          Oscillator(
            type: .triangle, frequency: range(params.tune, 1400, 2200),
            pitch: [Breakpoint(to: range(params.tune, 320, 520), at: 0.012)])),
        gain: 1, amp: strike(attack: 0.0005, decay: decay))
    ],
    filter: FilterSpec(type: .bandpass, frequency: range(params.tone, 1200, 2800), q: 1.4),
    gain: accentGain(params, accent) * 0.8, pan: range(params.pan, -1, 1))
}

private func maracas(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let decay = ratioRange(params.decay, 0.015, 0.14)
  return VoiceSpec(
    duration: decay + 0.03,
    sources: [Source(.noise(Noise()), gain: 1, amp: strike(attack: 0.0008, decay: decay))],
    filter: FilterSpec(type: .highpass, frequency: range(params.tone, 4000, 9000)),
    gain: accentGain(params, accent) * 0.6, pan: range(params.pan, -1, 1))
}

public let tr808Voices: [Voice] = [
  Voice(id: "808.bd", name: "Bass Drum", machine: .tr808, trim: 0.8, builder: bassDrum),
  Voice(id: "808.sd", name: "Snare", machine: .tr808, trim: 0.66, builder: snare),
  Voice(id: "808.cp", name: "Clap", machine: .tr808, trim: 3.35, builder: clap),
  Voice(id: "808.lt", name: "Low Tom", machine: .tr808, trim: 0.87, pitched: 55...105, builder: tom(55, 105)),
  Voice(id: "808.mt", name: "Mid Tom", machine: .tr808, trim: 0.86, pitched: 90...170, builder: tom(90, 170)),
  Voice(
    id: "808.ht", name: "Hi Tom", machine: .tr808, trim: 0.86, pitched: 140...265, builder: tom(140, 265)),
  Voice(id: "808.rs", name: "Rimshot", machine: .tr808, trim: 1.79, builder: rimshot),
  Voice(id: "808.cb", name: "Cowbell", machine: .tr808, trim: 2.16, builder: cowbell),
  Voice(
    id: "808.ch", name: "Closed Hat", machine: .tr808, choke: "808.hats", trim: 8.59,
    builder: metallic(decay: (0.02, 0.09), bandpass: 9400, q: 1.4)),
  Voice(
    id: "808.oh", name: "Open Hat", machine: .tr808, choke: "808.hats", trim: 4.28,
    builder: metallic(decay: (0.15, 0.9), bandpass: 8600, q: 1.2)),
  Voice(id: "808.ma", name: "Maracas", machine: .tr808, trim: 1.14, builder: maracas),
]
