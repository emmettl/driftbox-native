import DriftboxSeq

// The TR-909, as data. A port of `driftbox/packages/engine/src/voices/tr909.ts`, where the
// reasoning for each number lives. Held to it exactly by `conformance/fixtures/voices`.

private func bassDrum(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let base = range(params.tune, 44, 78)
  let decay = ratioRange(params.decay, 0.09, 0.85)

  return VoiceSpec(
    duration: decay + 0.08,
    sources: [
      Source(
        .oscillator(
          Oscillator(
            type: .sine, frequency: base * range(params.tone, 3.5, 7),
            pitch: [Breakpoint(to: base, at: 0.024)])),
        gain: 1, amp: strike(attack: 0.001, decay: decay)),
      Source(
        .noise(Noise()), gain: range(params.tone, 0.15, 0.6), amp: strike(attack: 0.0003, decay: 0.008),
        filter: FilterSpec(type: .highpass, frequency: 2400)),
    ],
    drive: range(params.colour, 0, 0.55), gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
}

private func snare(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let tune = ratioRange(params.tune, 0.8, 1.3)
  let snappy = range(params.colour, 0.25, 1)
  let noiseDecay = ratioRange(params.decay, 0.06, 0.45)
  let toneDecay = min(noiseDecay, 0.09)

  func body(_ frequency: Double, _ gain: Double) -> Source {
    Source(
      .oscillator(
        Oscillator(
          type: .triangle, frequency: frequency * tune,
          pitch: [Breakpoint(to: frequency * tune * 0.86, at: 0.03)])),
      gain: gain, amp: strike(attack: 0.0008, decay: toneDecay))
  }

  return VoiceSpec(
    duration: max(noiseDecay, toneDecay) + 0.05,
    sources: [
      body(175, (1 - snappy * 0.45) * 0.75),
      body(330, (1 - snappy * 0.45) * 0.4),
      Source(
        .noise(Noise()), gain: snappy * 1.15, amp: strike(attack: 0.0008, decay: noiseDecay),
        filter: FilterSpec(type: .highpass, frequency: range(params.tone, 1400, 4200))),
    ],
    drive: 0.12, gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
}

private func clap(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let decay = ratioRange(params.decay, 0.1, 0.5)
  let spacing = range(params.colour, 0.005, 0.013)

  func burst(_ delay: Double, _ gain: Double) -> Source {
    Source(.noise(Noise()), gain: gain, amp: strike(attack: 0.0005, decay: 0.009), delay: delay)
  }

  return VoiceSpec(
    duration: decay + spacing * 4 + 0.05,
    sources: [
      burst(0, 0.75),
      burst(spacing, 0.85),
      burst(spacing * 2, 0.95),
      burst(spacing * 3, 1),
      Source(.noise(Noise()), gain: 0.6, amp: strike(attack: 0.001, decay: decay), delay: spacing * 4),
    ],
    filter: FilterSpec(type: .bandpass, frequency: range(params.tone, 900, 2400), q: 2),
    drive: 0.18, gain: accentGain(params, accent) * 0.95, pan: range(params.pan, -1, 1))
}

private struct DigitalMetal {
  var decay: (Double, Double)
  var modes: [Double]
  var bandpass: Double
  var q: Double
  var highpass: Double
  var pcmGain: Double
  var modeGain: Double
  var seed: Double
}

/// Hats, ride and crash: a generated stand-in for the 909's PCM ROM. The noise layer is the dense
/// wash of a cymbal, rendered at about the original's 30kHz and 6 bits; quiet triangle modes add
/// the bell and plate resonances noise alone cannot.
private func digitalMetal(_ profile: DigitalMetal) -> @Sendable (VoiceParams, Double) -> VoiceSpec {
  { params, accent in
    let tune = ratioRange(params.tune, 0.82, 1.22)
    let decay = ratioRange(params.decay, profile.decay.0, profile.decay.1)
    let bright = ratioRange(params.tone, 0.65, 1.8)
    let definition = range(params.colour, 0.65, 1.25)

    var sources = [
      Source(
        .noise(Noise(sampleRate: 30000, bitDepth: 6, seed: profile.seed, playbackRate: tune)),
        gain: profile.pcmGain, amp: strike(attack: 0.0006, decay: decay),
        filter: FilterSpec(type: .highpass, frequency: profile.highpass))
    ]
    for (index, frequency) in profile.modes.enumerated() {
      let index = Double(index)
      sources.append(
        Source(
          .oscillator(Oscillator(type: .triangle, frequency: frequency * tune)),
          gain: profile.modeGain * definition * (1 - index * 0.07),
          amp: strike(attack: 0.0006, decay: decay * (0.55 + index * 0.07))))
    }

    return VoiceSpec(
      duration: decay + 0.05, sources: sources,
      filter: FilterSpec(type: .bandpass, frequency: profile.bandpass * bright, q: profile.q),
      gain: accentGain(params, accent) * 0.45, pan: range(params.pan, -1, 1))
  }
}

private func tom(_ low: Double, _ high: Double) -> @Sendable (VoiceParams, Double) -> VoiceSpec {
  { params, accent in
    let base = range(params.tune, low, high)
    let decay = ratioRange(params.decay, 0.12, 0.8)

    return VoiceSpec(
      duration: decay + 0.05,
      sources: [
        Source(
          .oscillator(
            Oscillator(type: .sine, frequency: base * 2.4, pitch: [Breakpoint(to: base, at: 0.09)])),
          gain: 1, amp: strike(attack: 0.002, decay: decay)),
        Source(
          .noise(Noise()), gain: range(params.colour, 0.02, 0.35), amp: strike(attack: 0.001, decay: 0.05),
          filter: FilterSpec(type: .highpass, frequency: 900)),
      ],
      gain: accentGain(params, accent), pan: range(params.pan, -1, 1))
  }
}

private func rim(_ params: VoiceParams, _ accent: Double) -> VoiceSpec {
  let decay = ratioRange(params.decay, 0.015, 0.07)
  return VoiceSpec(
    duration: decay + 0.03,
    sources: [
      Source(
        .oscillator(
          Oscillator(
            type: .square, frequency: range(params.tune, 1600, 2600),
            pitch: [Breakpoint(to: range(params.tune, 400, 700), at: 0.008)])),
        gain: 0.8, amp: strike(attack: 0.0004, decay: decay)),
      Source(.noise(Noise()), gain: 0.5, amp: strike(attack: 0.0004, decay: decay * 0.7)),
    ],
    filter: FilterSpec(type: .bandpass, frequency: range(params.tone, 1600, 3800), q: 1.6),
    gain: accentGain(params, accent) * 0.75, pan: range(params.pan, -1, 1))
}

private let hatModes: [Double] = [5100, 6230, 7410, 8740, 10480, 11800]

public let tr909Voices: [Voice] = [
  Voice(id: "909.bd", name: "Bass Drum", machine: .tr909, trim: 0.61, builder: bassDrum),
  Voice(id: "909.sd", name: "Snare", machine: .tr909, trim: 0.52, builder: snare),
  Voice(id: "909.cp", name: "Clap", machine: .tr909, trim: 1.06, builder: clap),
  Voice(id: "909.lt", name: "Low Tom", machine: .tr909, trim: 0.81, pitched: 65...122, builder: tom(65, 122)),
  Voice(
    id: "909.mt", name: "Mid Tom", machine: .tr909, trim: 0.8, pitched: 100...192, builder: tom(100, 192)),
  Voice(id: "909.ht", name: "Hi Tom", machine: .tr909, trim: 0.8, pitched: 150...288, builder: tom(150, 288)),
  Voice(id: "909.rim", name: "Rim", machine: .tr909, trim: 1.71, builder: rim),
  Voice(
    id: "909.ch", name: "Closed Hat", machine: .tr909, choke: "909.hats", trim: 3.23,
    builder: digitalMetal(
      DigitalMetal(
        decay: (0.018, 0.08), modes: hatModes, bandpass: 10800, q: 0.75, highpass: 6200, pcmGain: 0.9,
        modeGain: 0.075, seed: 0x909))),
  Voice(
    id: "909.oh", name: "Open Hat", machine: .tr909, choke: "909.hats", trim: 2.6,
    builder: digitalMetal(
      DigitalMetal(
        decay: (0.14, 0.8), modes: hatModes, bandpass: 9800, q: 0.65, highpass: 5200, pcmGain: 0.9,
        modeGain: 0.075, seed: 0x909))),
  Voice(
    id: "909.rd", name: "Ride", machine: .tr909, trim: 2.34,
    builder: digitalMetal(
      DigitalMetal(
        decay: (0.4, 1.6), modes: [1820, 2730, 3840, 5160, 6840, 8920], bandpass: 6200, q: 0.55,
        highpass: 1800,
        pcmGain: 0.62, modeGain: 0.15, seed: 0x90a))),
  Voice(
    id: "909.cr", name: "Crash", machine: .tr909, trim: 2.06,
    builder: digitalMetal(
      DigitalMetal(
        decay: (0.7, 2.6), modes: [1460, 2210, 3190, 4550, 6270, 8580], bandpass: 5200, q: 0.45,
        highpass: 1200,
        pcmGain: 0.78, modeGain: 0.11, seed: 0x90b))),
]
