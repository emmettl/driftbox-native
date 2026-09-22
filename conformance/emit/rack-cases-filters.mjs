// The filters family's rack cases: the Alligator and the Vocoder. Each is [name, patch, blocks,
// events?, hostBuses?], in the shape `emit.mjs` documents beside its own cases.
//
// Knob moves made with `param` or `schedule` are not clamped to the def's range (only a patch's
// saved values are), so the extremes cases push a few past it on purpose, to reach the branches a
// knob cannot: a zero attack or decay, a frequency above the 0.45·sr ceiling, a band selector off
// either end.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

// The Alligator's three outlets, summed so all three are held to the reference.
const threeBands = (id) => [
  c([id, 'out1'], ['mix', 'in1']), c([id, 'out2'], ['mix', 'in2']), c([id, 'out3'], ['mix', 'in3']),
  c(['mix', 'out'], ['out', 'in']),
]

// A modulator with a rhythm in it: pink noise through a VCA opened by a plucked envelope.
const hissPluck = (rate) => ({
  modules: [
    m('hiss', 'noise'), m('clock', 'lfo', { rate, shape: 3 }),
    m('env', 'adsr', { attack: 0.001, decay: 0.06, sustain: 0.1, release: 0.04 }), m('amp', 'vca', { gain: 0 }),
  ],
  cables: [
    c(['hiss', 'pink'], ['amp', 'in']), c(['clock', 'uni'], ['env', 'gate']), c(['env', 'out'], ['amp', 'cv']),
  ],
})

export default [
  // The device as it comes: a saw pad through the three default bands, each gated by a square clock
  // at its own rate, so the bands open and close independently.
  ['filters-alligator-gates', {
    modules: [
      m('osc', 'vco', { tune: -12 }),
      m('g1', 'lfo', { rate: 20, shape: 3 }), m('g2', 'lfo', { rate: 45, shape: 3 }), m('g3', 'lfo', { rate: 80, shape: 3 }),
      m('gator', 'alligator'), m('mix', 'mixer', { level1: 0.5, level2: 0.5, level3: 0.5 }), m('out', 'out', { level: 0.5 }),
    ],
    cables: [
      c(['osc', 'out'], ['gator', 'in']),
      c(['g1', 'uni'], ['gator', 'gate1']), c(['g2', 'uni'], ['gator', 'gate2']), c(['g3', 'uni'], ['gator', 'gate3']),
      ...threeBands('gator'),
    ],
  }, 64],

  // Every knob at its ends from the patch, then moved mid-render: a resonance ramp alone (the path
  // that recovers g from the cached coefficients), a frequency ramp, and the zero-time and
  // over-ceiling values a cable-free knob move can reach.
  ['filters-alligator-extremes', {
    modules: [
      m('hiss', 'noise'), m('g1', 'lfo', { rate: 30, shape: 3 }), m('g2', 'lfo', { rate: 55, shape: 3 }),
      m('gator', 'alligator', {
        attack: 0.2, freq1: 20, freq2: 18000, freq3: 20, res1: 1, res2: 0, res3: 1,
        decay1: 0.001, decay2: 2, decay3: 0.001, level1: 2, level2: 0, level3: 2,
      }),
      m('mix', 'mixer', { level1: 0.3, level2: 0.3, level3: 0.3 }), m('out', 'out', { level: 0.5 }),
    ],
    cables: [
      c(['hiss', 'white'], ['gator', 'in']),
      c(['g1', 'uni'], ['gator', 'gate1']), c(['g2', 'uni'], ['gator', 'gate2']), c(['g1', 'uni'], ['gator', 'gate3']),
      ...threeBands('gator'),
    ],
  }, 64, [
    [8, 'param', 'gator', 'attack', 0.0005], [8, 'param', 'gator', 'level2', 2],
    [16, 'param', 'gator', 'res1', 0], [16, 'param', 'gator', 'res2', 1], [16, 'param', 'gator', 'res3', 0],
    [24, 'param', 'gator', 'freq1', 18000], [24, 'param', 'gator', 'freq3', 9000], [24, 'param', 'gator', 'freq2', 20],
    [32, 'param', 'gator', 'decay1', 2], [32, 'param', 'gator', 'decay2', 0.001], [32, 'param', 'gator', 'decay3', 0.3],
    [40, 'param', 'gator', 'attack', 0], [40, 'param', 'gator', 'decay3', 0], [40, 'param', 'gator', 'freq2', 30000],
    [48, 'schedule', 'gator', 'res2', 0.4, 48 * 128 + 70], [48, 'param', 'gator', 'level1', 0],
    [56, 'param', 'gator', 'freq1', 5], [56, 'param', 'gator', 'res1', 2], [56, 'param', 'gator', 'res3', -1],
  ]],

  // Continuous signals on the gates, crossing the 0.5 threshold where they will: a sine LFO and an
  // envelope, with the third band left unpatched and so shut, while knobs move the other two.
  ['filters-alligator-cv', {
    modules: [
      m('osc', 'vco', { shape: 1, width: 0.3, tune: -5 }), m('sine', 'lfo', { rate: 35 }),
      m('clock', 'lfo', { rate: 25, shape: 3 }), m('env', 'adsr', { attack: 0.005, decay: 0.01, sustain: 0.3, release: 0.01 }),
      m('gator', 'alligator', { freq1: 400, freq2: 2500, res2: 0.9, decay1: 0.05, decay2: 0.5 }),
      m('mix', 'mixer', { level1: 0.4, level2: 0.4, level3: 0.4 }), m('out', 'out', { level: 0.5 }),
    ],
    cables: [
      c(['osc', 'out'], ['gator', 'in']), c(['sine', 'uni'], ['gator', 'gate1']),
      c(['clock', 'uni'], ['env', 'gate']), c(['env', 'out'], ['gator', 'gate2']),
      ...threeBands('gator'),
    ],
  }, 48, [[16, 'param', 'gator', 'freq2', 600], [24, 'schedule', 'gator', 'freq1', 3000, 24 * 128 + 9], [32, 'param', 'gator', 'attack', 0.05]]],

  // The default bank of 16 on a saw, the modulator a plucked noise, then 8 and 32 bands mid-render
  // (each change rebuilding the bank and clearing its state), and the selector pushed off both ends.
  ['filters-vocoder-bands', (() => {
    const mod = hissPluck(30)
    return {
      modules: [...mod.modules, m('saw', 'vco', { tune: -12 }), m('voc', 'vocoder'), m('out', 'out', { level: 0.15 })],
      cables: [...mod.cables, c(['saw', 'out'], ['voc', 'carrier']), c(['amp', 'out'], ['voc', 'mod']), c(['voc', 'out'], ['out', 'in'])],
    }
  })(), 72, [
    [16, 'param', 'voc', 'bands', 0], [32, 'param', 'voc', 'bands', 2],
    [48, 'param', 'voc', 'bands', 7], [56, 'param', 'voc', 'bands', -3], [64, 'param', 'voc', 'bands', 1],
  ]],

  // The shift, down and up and off the end, with some dry carrier in, on 32 bands.
  ['filters-vocoder-shift', (() => {
    const mod = hissPluck(45)
    return {
      modules: [...mod.modules, m('saw', 'vco', { tune: -7 }), m('voc', 'vocoder', { bands: 2, shift: -12, dry: 0.2 }), m('out', 'out', { level: 0.15 })],
      cables: [...mod.cables, c(['saw', 'out'], ['voc', 'carrier']), c(['amp', 'out'], ['voc', 'mod']), c(['voc', 'out'], ['out', 'in'])],
    }
  })(), 64, [
    [12, 'param', 'voc', 'shift', 12], [24, 'param', 'voc', 'shift', 3], [32, 'param', 'voc', 'shift', -5],
    [40, 'param', 'voc', 'shift', 40], [48, 'param', 'voc', 'shift', 1.4], [48, 'param', 'voc', 'dry', 0],
  ]],

  // A second VCO as the modulator, swept by an LFO through a VCA, and every time knob at its ends,
  // then a hot carrier with the dry at full to reach the ±4 clamp.
  ['filters-vocoder-extremes', {
    modules: [
      m('carrier', 'vco', { shape: 1, width: 0.4, tune: -12 }), m('hot', 'mixer', { level1: 0.5, level2: 0.5 }),
      m('talk', 'vco', { tune: 5 }), m('sweep', 'lfo', { rate: 20 }), m('wobble', 'lfo', { rate: 6 }), m('amp', 'vca', { gain: 0 }),
      m('voc', 'vocoder', { bands: 0, attack: 0.2, release: 1 }), m('out', 'out', { level: 0.2 }),
    ],
    cables: [
      c(['carrier', 'out'], ['hot', 'in1']), c(['carrier', 'out'], ['hot', 'in2']),
      c(['wobble', 'bi'], ['talk', 'pitch']), c(['talk', 'out'], ['amp', 'in']), c(['sweep', 'uni'], ['amp', 'cv']),
      c(['hot', 'out'], ['voc', 'carrier']), c(['amp', 'out'], ['voc', 'mod']), c(['voc', 'out'], ['out', 'in']),
    ],
  }, 64, [
    [16, 'param', 'voc', 'attack', 0.0005], [16, 'param', 'voc', 'release', 0.001],
    [32, 'param', 'voc', 'attack', 0], [32, 'param', 'voc', 'release', 0], [32, 'param', 'voc', 'bands', 1],
    [48, 'param', 'voc', 'dry', 1], [48, 'param', 'hot', 'level1', 2], [48, 'param', 'hot', 'level2', 2], [48, 'schedule', 'voc', 'release', 0.3, 48 * 128 + 40],
  ]],
]
