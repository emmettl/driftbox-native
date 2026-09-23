// The shaping family's rack cases: drive, distortion, cabinet, eq, imager, compressor, limiter.
// Each is [name, patch, blocks, events?, hostBuses?], in the shape `emit.mjs` documents beside its
// own cases, and is rendered by the reference's headless renderer.
//
// Every stereo port here is fed from a mono source, so both channels carry the same signal: none of
// the modules ported so far has a stereo outlet whose sides differ. The imager's side is therefore
// silent in these renders; its crossover and widths are held to the reference once a stereo source
// exists to feed it.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

// A plucked saw: a square clock into a short envelope into a VCA, for anything that wants dynamics.
const pluck = (rate = 6, tune = -12, shape = 0) => ({
  modules: [
    m('clock', 'lfo', { rate, shape: 3 }),
    m('env', 'adsr', { attack: 0.001, decay: 0.08, sustain: 0.2, release: 0.03 }),
    m('osc', 'vco', { tune, shape }),
    m('amp', 'vca', { gain: 0 }),
  ],
  cables: [
    c(['clock', 'uni'], ['env', 'gate']),
    c(['osc', 'out'], ['amp', 'in']),
    c(['env', 'out'], ['amp', 'cv']),
  ],
})

export default [
  // Drive: bias for the even harmonics and the DC blocker behind them, and a CV swinging the amount
  // through both of its clamps.
  ['shaping-drive-cv', {
    modules: [m('osc', 'vco', { tune: -12 }), m('swing', 'lfo', { rate: 9 }), m('fuzz', 'drive', { drive: 8, bias: 0.3 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['fuzz', 'in']), c(['swing', 'bi'], ['fuzz', 'cv']), c(['fuzz', 'out'], ['out', 'in'])],
  }, 32],
  ['shaping-drive-knobs', {
    modules: [m('hiss', 'noise'), m('fuzz', 'drive', { drive: 2 }), m('out', 'out')],
    cables: [c(['hiss', 'pink'], ['fuzz', 'in']), c(['fuzz', 'out'], ['out', 'in'])],
  }, 32, [
    [8, 'param', 'fuzz', 'drive', 40], [12, 'param', 'fuzz', 'bias', -1],
    [16, 'param', 'fuzz', 'drive', 0.1], [20, 'schedule', 'fuzz', 'bias', 1, 20 * 128 + 50],
    [24, 'param', 'fuzz', 'drive', 17],
  ]],

  // Distortion: every mode in turn, then the digital mode's bit depth swept by the amount CV.
  ['shaping-distortion-modes', {
    modules: [m('osc', 'vco', { tune: -5 }), m('dirt', 'distortion', { amount: 0.6, bias: 0.2, tone: 3000 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['dirt', 'in']), c(['dirt', 'out'], ['out', 'in'])],
  }, 40, [
    [8, 'param', 'dirt', 'mode', 1], [16, 'param', 'dirt', 'mode', 2], [24, 'param', 'dirt', 'mode', 3],
    [32, 'param', 'dirt', 'mode', 0], [34, 'param', 'dirt', 'bias', -0.5],
  ]],
  ['shaping-distortion-digital', {
    modules: [m('osc', 'vco', { shape: 2 }), m('sweep', 'lfo', { rate: 2, shape: 1 }), m('dirt', 'distortion', { mode: 3, amount: 0, tone: 18000, level: 1.5 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['dirt', 'in']), c(['sweep', 'uni'], ['dirt', 'amount']), c(['dirt', 'out'], ['out', 'in'])],
  }, 48, [[24, 'schedule', 'dirt', 'tone', 200, 24 * 128 + 64], [32, 'param', 'dirt', 'amount', 1]]],
  ['shaping-distortion-extremes', {
    modules: [m('hiss', 'noise'), m('dirt', 'distortion', { mode: 2, amount: 1, bias: -0.5, level: 0 }), m('out', 'out')],
    cables: [c(['hiss', 'white'], ['dirt', 'in']), c(['dirt', 'out'], ['out', 'in'])],
  }, 32, [
    [2, 'param', 'dirt', 'level', 1.2], [12, 'param', 'dirt', 'mode', 1], [12, 'param', 'dirt', 'bias', 0.5],
    [20, 'param', 'dirt', 'mode', 0], [20, 'param', 'dirt', 'amount', 0],
  ]],

  // Cabinet: the three voicings under a tone stack, then every knob at its ends with the drive CV moving.
  ['shaping-cabinet-voicings', {
    modules: [m('osc', 'vco', { tune: -12 }), m('amp', 'cabinet', { drive: 12, bass: 6, mid: -6, treble: 3 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['amp', 'in']), c(['amp', 'out'], ['out', 'in'])],
  }, 36, [[12, 'param', 'amp', 'cabinet', 1], [24, 'param', 'amp', 'cabinet', 2]]],
  ['shaping-cabinet-extremes', {
    modules: [m('hiss', 'noise'), m('wobble', 'lfo', { rate: 7 }), m('amp', 'cabinet', { cabinet: 2, drive: 30, bass: -12, mid: 12, treble: -12, level: 1.5 }), m('out', 'out')],
    cables: [c(['hiss', 'white'], ['amp', 'in']), c(['wobble', 'bi'], ['amp', 'drive']), c(['amp', 'out'], ['out', 'in'])],
  }, 32, [
    [8, 'param', 'amp', 'bass', 12], [8, 'param', 'amp', 'treble', 12], [16, 'param', 'amp', 'drive', 0.5],
    [16, 'param', 'amp', 'mid', -12], [24, 'param', 'amp', 'level', 0.4], [24, 'param', 'amp', 'cabinet', 0],
  ]],

  // EQ: all three bands boosted and cut at their ends, and knobs moved so the coefficients are
  // recomputed sample by sample while they ramp.
  ['shaping-eq-bands', {
    modules: [m('hiss', 'noise'), m('tone', 'eq', { low: 12, lowFreq: 80, mid: -9, midFreq: 800, q: 4, high: 6, highFreq: 9000 }), m('out', 'out')],
    cables: [c(['hiss', 'white'], ['tone', 'in']), c(['tone', 'out'], ['out', 'in'])],
  }, 32, [
    [8, 'param', 'tone', 'mid', 18], [8, 'param', 'tone', 'q', 0.3], [8, 'param', 'tone', 'midFreq', 8000],
    [16, 'param', 'tone', 'low', -18], [16, 'param', 'tone', 'lowFreq', 500], [16, 'param', 'tone', 'high', -18], [16, 'param', 'tone', 'highFreq', 16000],
    [24, 'schedule', 'tone', 'q', 8, 24 * 128 + 17], [24, 'param', 'tone', 'lowFreq', 40], [24, 'param', 'tone', 'highFreq', 1500], [24, 'param', 'tone', 'midFreq', 100],
  ]],
  ['shaping-eq-default', {
    modules: [m('osc', 'vco', { shape: 1, width: 0.2 }), m('tone', 'eq'), m('out', 'out')],
    cables: [c(['osc', 'out'], ['tone', 'in']), c(['tone', 'out'], ['out', 'in'])],
  }, 16, [[8, 'param', 'tone', 'high', 9]]],

  // Imager: with a mono source the side is silent, so this holds the def, the plan and the transparent
  // path while every knob moves.
  ['shaping-imager', {
    modules: [m('osc', 'vco', { tune: 7 }), m('width', 'imager', { lowWidth: 0, highWidth: 2, crossover: 60 }), m('out', 'out')],
    cables: [c(['osc', 'out'], ['width', 'in']), c(['width', 'out'], ['out', 'in'])],
  }, 16, [[8, 'param', 'width', 'crossover', 2000], [8, 'param', 'width', 'lowWidth', 2], [12, 'param', 'width', 'highWidth', 0]]],

  // Compressor: reading its own input with a hard knee and makeup, then keyed from a separate pluck
  // with a soft knee, where the silent gaps in the key drop it back to self-detection block by block.
  // The gain-reduction outlet is mixed in so it is held to the reference too.
  ['shaping-compressor-self', (() => {
    const p = pluck(5, -12)
    return {
      modules: [...p.modules, m('comp', 'compressor', { threshold: -30, ratio: 8, attack: 0.001, release: 0.05, makeup: 6, knee: 0 }), m('mix', 'mixer', { level1: 0.5, level2: 1 }), m('out', 'out')],
      cables: [...p.cables, c(['amp', 'out'], ['comp', 'in']), c(['comp', 'out'], ['mix', 'in1']), c(['comp', 'gain'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in'])],
    }
  })(), 64, [[32, 'param', 'comp', 'knee', 24], [40, 'param', 'comp', 'attack', 0.2], [48, 'param', 'comp', 'ratio', 1]]],
  ['shaping-compressor-keyed', {
    modules: [
      m('clock', 'lfo', { rate: 4, shape: 3 }), m('kick', 'adsr', { attack: 0.0005, decay: 0.02, sustain: 0, release: 0.0005 }),
      m('bass', 'vco', { tune: -24 }), m('comp', 'compressor', { threshold: -40, ratio: 20, attack: 0.0001, release: 1, knee: 12 }),
      m('mix', 'mixer', { level1: 1, level2: 0.5 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['kick', 'gate']), c(['kick', 'out'], ['comp', 'key']), c(['bass', 'out'], ['comp', 'in']),
      c(['comp', 'out'], ['mix', 'in1']), c(['comp', 'gain'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 64, [[32, 'param', 'comp', 'release', 0.005], [32, 'param', 'comp', 'threshold', -60], [40, 'param', 'comp', 'knee', 0], [48, 'param', 'comp', 'makeup', 24]]],

  // Limiter: a pluck pushed into the ceiling so gain attacks through the look-ahead and releases
  // between notes, then the knobs at their ends. GR goes to a second Out.
  ['shaping-limiter', (() => {
    const p = pluck(7, -7, 1)
    return {
      modules: [...p.modules, m('lim', 'limiter', { inputGain: 12, ceiling: -6, release: 0.05 }), m('out', 'out'), m('gr', 'out', { level: 0.5 })],
      cables: [...p.cables, c(['amp', 'out'], ['lim', 'in']), c(['lim', 'out'], ['out', 'in']), c(['lim', 'gain'], ['gr', 'in'])],
    }
  })(), 48],
  ['shaping-limiter-knobs', {
    modules: [m('hiss', 'noise'), m('lim', 'limiter', { inputGain: 24, ceiling: -12, release: 1 }), m('out', 'out'), m('gr', 'out', { level: 0.3 })],
    cables: [c(['hiss', 'white'], ['lim', 'in']), c(['lim', 'out'], ['out', 'in']), c(['lim', 'gain'], ['gr', 'in'])],
  }, 32, [[8, 'param', 'lim', 'ceiling', 0], [16, 'param', 'lim', 'release', 0.01], [16, 'param', 'lim', 'inputGain', 0], [24, 'param', 'lim', 'inputGain', 6]]],
]
