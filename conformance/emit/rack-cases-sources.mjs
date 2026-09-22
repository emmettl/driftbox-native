// The sources: wavetable, voice, sampler, multisampler, audio input and audio track, rendered by
// the reference. Cases are [name, patch, blocks, events?, hostBuses?] — see emit.mjs.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

// Short recordings, synthesised so they are the same everywhere: a decaying tone with a little
// saw in it, so slices and zones sound different from one another. Rounded to float32 first, so
// the JSON holds exactly what both sides will play.
const tone = (length, frequency, decay, saw = 0.3) =>
  Array.from({ length }, (_, n) => {
    const phase = (frequency * n) / 48000
    const value = (Math.sin(2 * Math.PI * phase) + saw * (2 * (phase - Math.floor(phase)) - 1)) * Math.exp(-n / decay)
    return Math.fround(value * 0.8)
  })
// A drum-ish break: four hits, each a click and a falling tone, so every slice starts differently.
const hits = (length) =>
  Array.from({ length }, (_, n) => {
    const at = n % (length / 4)
    const hit = Math.floor(n / (length / 4))
    const pitch = 90 + 70 * hit
    return Math.fround(Math.sin((2 * Math.PI * pitch * at) / 48000 * (1 + 2 * Math.exp(-at / 200))) * Math.exp(-at / (300 + 150 * hit)))
  })

// A zone: root, low, high, velocity low, velocity high, loop start, loop end, loop, sample rate.
const zone = (root, low, high, velocityLow, velocityHigh, loopStart, loopEnd, loop, sampleRate) =>
  [root, low, high, velocityLow, velocityHigh, loopStart, loopEnd, loop, sampleRate]

export default [
  // --- Wavetable ---------------------------------------------------------------------------------
  // Position swept across the whole bank by a slow triangle, at a pitch that stays on one mip level.
  ['sources-wavetable-sweep', {
    modules: [
      m('sweep', 'lfo', { rate: 3, shape: 1 }), m('osc', 'wavetable', { tune: -5, position: 0.5 }), m('out', 'out'),
    ],
    cables: [c(['sweep', 'bi'], ['osc', 'pos']), c(['osc', 'out'], ['out', 'in'])],
  }, 32, [[12, 'param', 'osc', 'position', 0.1], [20, 'param', 'osc', 'position', 0.93]]],
  // Pitch swept over five octaves, crossing mip levels and their fades, with FM and position moved.
  ['sources-wavetable-pitch', {
    modules: [
      m('sweep', 'lfo', { rate: 2.5 }), m('span', 'offset', { gain: 2.5, offset: 3 }),
      m('wobble', 'lfo', { rate: 7, shape: 2 }),
      m('osc', 'wavetable', { tune: 12, position: 0.62 }), m('out', 'out'),
    ],
    cables: [
      c(['sweep', 'bi'], ['span', 'in']), c(['span', 'out'], ['osc', 'pitch']),
      c(['wobble', 'bi'], ['osc', 'fm']), c(['osc', 'out'], ['out', 'in']),
    ],
  }, 48, [[30, 'param', 'osc', 'position', 1], [40, 'param', 'osc', 'tune', -24]]],
  // Two-operator FM: a sine at position 0 phase-modulated by a VCO, the index swept, then driven hard.
  ['sources-wavetable-pm', {
    modules: [
      m('mod', 'vco', { shape: 2, tune: 19 }), m('osc', 'wavetable', { position: 0, index: 0.8 }),
      m('sweep', 'lfo', { rate: 1.5, shape: 2 }), m('out', 'out'),
    ],
    cables: [
      c(['mod', 'out'], ['osc', 'pm']), c(['sweep', 'uni'], ['osc', 'pos']), c(['osc', 'out'], ['out', 'in']),
    ],
  }, 32, [[10, 'param', 'osc', 'index', 3.6], [22, 'param', 'osc', 'index', 0]]],
  // Three voices, each its own note and position.
  ['sources-wavetable-poly', {
    voices: 3,
    modules: [m('osc', 'wavetable', { tune: -12 }), m('amp', 'vca', { gain: 0.3 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['amp', 'in']), c(['amp', 'out'], ['out', 'in'])],
  }, 24, [
    [0, 'voice', 'osc', 'tune', 0, 0], [0, 'voice', 'osc', 'tune', 4, 1], [0, 'voice', 'osc', 'tune', 7, 2],
    [0, 'voice', 'osc', 'position', 0.2, 0], [0, 'voice', 'osc', 'position', 0.55, 1], [0, 'voice', 'osc', 'position', 0.97, 2],
  ]],

  // --- Voice -------------------------------------------------------------------------------------
  // Plucks from a square clock, the pitch wandering under them, both oscillators saw.
  ['sources-voice-pluck', {
    modules: [
      m('clock', 'lfo', { rate: 25, shape: 3 }), m('wander', 'lfo', { rate: 4, shape: 1 }),
      m('synth', 'voice', { detune: 12, cutoff: 600, resonance: 0.5, envAmount: 4, decay: 0.08, sustain: 0.2, release: 0.05, fDecay: 0.06 }),
      m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['synth', 'gate']), c(['wander', 'bi'], ['synth', 'pitch']), c(['synth', 'out'], ['out', 'in']),
    ],
  }, 64],
  // Glide between two notes, a pulse against a triangle, the cutoff swept by a cable and the envelope
  // out mixed in.
  ['sources-voice-glide', {
    modules: [
      m('gate', 'lfo', { rate: 16, shape: 3 }), m('steps', 'lfo', { rate: 7, shape: 3 }),
      m('sweep', 'lfo', { rate: 5 }),
      m('synth', 'voice', { shapeA: 1, shapeB: 2, width: 0.3, mix: 0.35, glide: 0.04, attack: 0.02, keyTrack: 0.8, resonance: 0.7 }),
      m('mix', 'mixer', { level2: 0.1 }), m('out', 'out'),
    ],
    cables: [
      c(['gate', 'uni'], ['synth', 'gate']), c(['steps', 'bi'], ['synth', 'pitch']), c(['sweep', 'bi'], ['synth', 'cutoff']),
      c(['synth', 'out'], ['mix', 'in1']), c(['synth', 'env'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 64, [[40, 'param', 'synth', 'glide', 0], [48, 'param', 'synth', 'attack', 0]]],
  // A three-note chord, each voice gated by its own clock.
  ['sources-voice-poly', {
    voices: 3,
    modules: [
      m('clock', 'lfo', { rate: 20, shape: 3 }),
      m('synth', 'voice', { tune: -12, detune: -20, release: 0.1, level: 0.5 }), m('out', 'out'),
    ],
    cables: [c(['clock', 'uni'], ['synth', 'gate']), c(['synth', 'out'], ['out', 'in'])],
  }, 48, [
    [0, 'voice', 'synth', 'tune', 0, 0], [0, 'voice', 'synth', 'tune', 3, 1], [0, 'voice', 'synth', 'tune', 7, 2],
    [0, 'voice', 'clock', 'rate', 17, 1], [0, 'voice', 'clock', 'rate', 23, 2],
  ]],

  // --- Sampler -----------------------------------------------------------------------------------
  // Eight slices of a break, retriggered by a clock with the slice chosen by a ramp and the pitch
  // wobbling; EOC mixed in quietly.
  ['sources-sampler-slices', {
    modules: [
      m('clock', 'lfo', { rate: 40, shape: 3 }), m('pick', 'lfo', { rate: 4, shape: 2 }),
      m('bend', 'lfo', { rate: 3 }), m('scale', 'offset', { gain: 0.4, offset: 0 }),
      m('chop', 'sampler', { slices: 8 }, { data: { sample: hits(2400) } }),
      m('mix', 'mixer', { level2: 0.05 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['chop', 'trig']), c(['pick', 'uni'], ['chop', 'slice']),
      c(['bend', 'bi'], ['scale', 'in']), c(['scale', 'out'], ['chop', 'pitch']),
      c(['chop', 'out'], ['mix', 'in1']), c(['chop', 'eoc'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 96, [[60, 'param', 'chop', 'start', 0.3]]],
  // Reversed and looping from a start point, pitched down; the break replaced mid-play, then the loop
  // turned off.
  ['sources-sampler-reverse-loop', {
    modules: [
      m('clock', 'lfo', { rate: 25, shape: 3 }), m('down', 'offset', { gain: 0, offset: -0.5 }),
      m('chop', 'sampler', { slices: 4, slice: 2, start: 0.25, loop: 1, reverse: 1 }, { data: { sample: hits(2400) } }),
      m('mix', 'mixer', { level2: 0.05 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['chop', 'trig']), c(['down', 'out'], ['chop', 'pitch']),
      c(['chop', 'out'], ['mix', 'in1']), c(['chop', 'eoc'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 96, [
    [22, 'data', 'chop', 'sample', tone(1800, 330, 900)], [40, 'param', 'chop', 'reverse', 0],
    [55, 'param', 'chop', 'loop', 0], [70, 'param', 'chop', 'slices', 3], [70, 'param', 'chop', 'slice', 5],
  ]],
  // No recording at first, so silent; one arrives, then two voices play different slices.
  ['sources-sampler-late-data', {
    voices: 2,
    modules: [
      m('clock', 'lfo', { rate: 30, shape: 3 }), m('up', 'offset', { gain: 0, offset: 0.7 }),
      m('chop', 'sampler', { slices: 5 }), m('amp', 'vca', { gain: 0.6 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['chop', 'trig']), c(['up', 'out'], ['chop', 'pitch']),
      c(['chop', 'out'], ['amp', 'in']), c(['amp', 'out'], ['out', 'in']),
    ],
  }, 64, [
    [0, 'voice', 'chop', 'slice', 1, 0], [0, 'voice', 'chop', 'slice', 3, 1],
    [6, 'data', 'chop', 'sample', tone(2000, 180, 1200, 0.8)],
  ]],

  // --- Multisampler ------------------------------------------------------------------------------
  // Three zones across the keyboard with two velocity layers, one of them looping; notes from a
  // stepped LFO held by a sample-and-hold, velocities from another.
  ['sources-multisampler-zones', {
    modules: [
      m('gate', 'lfo', { rate: 20, shape: 3 }), m('notes', 'lfo', { rate: 3, shape: 1 }), m('hold', 'sample-hold'),
      m('span', 'offset', { gain: 1.5, offset: 1.5 }), m('touch', 'lfo', { rate: 7, shape: 2 }),
      m('press', 'offset', { gain: 0.45, offset: 0.5 }),
      m('keys', 'multisampler', { attack: 0.004, release: 0.06 }, {
        data: {
          zones: [
            ...zone(48, 0, 55, 0, 0.5, 0.2, 0.6, 1, 48000),
            ...zone(50, 0, 55, 0.5, 1, 0, 1, 0, 44100),
            ...zone(64, 56, 127, 0, 1, 0.1, 0.9, 1, 32000),
          ],
          sample0: tone(3000, 130.8, 1500),
          sample1: tone(2800, 146.8, 1100, 0.6),
          sample2: tone(2600, 329.6, 5000, 0),
        },
      }),
      m('mix', 'mixer', { level2: 0.1 }), m('out', 'out'),
    ],
    cables: [
      c(['gate', 'uni'], ['hold', 'trig']), c(['notes', 'bi'], ['hold', 'in']), c(['hold', 'out'], ['span', 'in']),
      c(['span', 'out'], ['keys', 'pitch']), c(['gate', 'uni'], ['keys', 'gate']), c(['touch', 'bi'], ['press', 'in']), c(['press', 'out'], ['keys', 'velocity']),
      c(['keys', 'out'], ['mix', 'in1']), c(['keys', 'env'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 96, [[40, 'param', 'keys', 'velocity', 0.4], [60, 'param', 'keys', 'tune', 7]]],
  // No zones: the first recording, pushed by the host, plays at its own pitch and is transposed.
  ['sources-multisampler-fallback', {
    modules: [
      m('gate', 'lfo', { rate: 30, shape: 3 }), m('pitch', 'lfo', { rate: 7, shape: 3 }),
      m('keys', 'multisampler', { attack: 0, release: 0.02, tune: -3 }), m('out', 'out'),
    ],
    cables: [c(['gate', 'uni'], ['keys', 'gate']), c(['pitch', 'uni'], ['keys', 'pitch']), c(['keys', 'out'], ['out', 'in'])],
  }, 48, [[2, 'data', 'keys', 'sample0', tone(6000, 220, 2500, 0.5)], [30, 'param', 'keys', 'level', 0.4]]],
  // Three voices, one sustain-looped zone at another sample rate, each voice its own note; the gate
  // held long enough to loop, then released.
  ['sources-multisampler-poly', {
    voices: 3,
    modules: [
      m('gate', 'lfo', { rate: 1.6, shape: 3 }),
      m('keys', 'multisampler', { attack: 0.01, release: 0.03, level: 0.5 }, {
        data: { zones: zone(60, 0, 127, 0, 1, 0.25, 0.75, 1, 44100), sample0: tone(1200, 261.6, 20000, 0.4) },
      }),
      m('out', 'out'),
    ],
    cables: [c(['gate', 'uni'], ['keys', 'gate']), c(['keys', 'out'], ['out', 'in'])],
  }, 48, [
    [0, 'voice', 'keys', 'tune', 24, 0], [0, 'voice', 'keys', 'tune', 28, 1], [0, 'voice', 'keys', 'tune', 31, 2],
  ]],

  // --- Audio input -------------------------------------------------------------------------------
  // The host's bus 4, left then right, at two levels.
  ['sources-audio-input', {
    modules: [m('mic', 'audio-input', { level: 0.8 }), m('out', 'out')],
    cables: [c(['mic', 'out'], ['out', 'in'])],
  }, 16, [[6, 'param', 'mic', 'channel', 1], [10, 'param', 'mic', 'level', 2.5]], 5],
  // No bus 4 from the host: silence beside a VCO, never another bus.
  ['sources-audio-input-absent', {
    modules: [m('mic', 'audio-input'), m('osc', 'vco'), m('mix', 'mixer', { level2: 0.3 }), m('out', 'out')],
    cables: [c(['mic', 'out'], ['mix', 'in1']), c(['osc', 'out'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in'])],
  }, 8, [], 4],

  // --- Audio track -------------------------------------------------------------------------------
  // A stereo recording at 44.1 kHz placed one sixteenth in, played once when the transport reaches it.
  ['sources-audio-track', {
    modules: [
      m('track', 'audio-track', { start: 1, level: 0.9 }, {
        data: { left: tone(2400, 200, 1400), right: tone(2400, 300, 900, 0.7), sampleRate: [44100] },
      }),
      m('out', 'out', { level: 1 }),
    ],
    cables: [c(['track', 'out'], ['out', 'in'])],
  }, 48, [[2, 'transport', 300, 1, 0]]],
  // Mono, loaded while the transport is already past its start (so it seeks), stopped, started
  // again (re-armed from the top), moved, and turned up.
  ['sources-audio-track-seek', {
    modules: [m('track', 'audio-track'), m('out', 'out', { level: 1 })],
    cables: [c(['track', 'out'], ['out', 'in'])],
  }, 56, [
    [0, 'transport', 240, 1, 0], [8, 'data', 'track', 'left', tone(3000, 250, 3000, 0.2)],
    [20, 'transport', 240, 0, 0], [24, 'transport', 240, 1, 0], [34, 'param', 'track', 'start', 1],
    [40, 'param', 'track', 'level', 1.5],
  ]],
]
