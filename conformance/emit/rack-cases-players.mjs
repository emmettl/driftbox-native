// The players family's rack cases: the arpeggiator, the scale player and the chord player. Read by
// emit.mjs, which renders each through the reference's headless RackRenderer. A case is
// [name, patch, blocks, events, host buses]; see emit.mjs for the event shapes.
//
// Every case listens to the players' control voltages directly rather than through an oscillator,
// so a difference in a single step shows as a difference in the render: two Outs panned hard left
// and right each carry a Mixer of several outlets at different weights, kept under the master
// limiter's threshold.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

// Two mixers of up to four [module, outlet, weight] taps, to the left and right of the mix.
const probe = (left, right) => {
  const modules = []
  const cables = []
  for (const [side, taps, pan] of [['l', left, -1], ['r', right, 1]]) {
    const levels = {}
    taps.forEach(([, , weight], at) => { levels[`level${at + 1}`] = weight })
    modules.push(m(`mix-${side}`, 'mixer', levels), m(`out-${side}`, 'out', { level: 1, pan }))
    taps.forEach(([module, outlet], at) => cables.push(c([module, outlet], [`mix-${side}`, `in${at + 1}`])))
    cables.push(c([`mix-${side}`, 'out'], [`out-${side}`, 'in']))
  }
  return { modules, cables }
}

const arpProbe = (id, extraLeft = [], extraRight = []) =>
  probe(
    [[id, 'pitch', 0.1], [id, 'velocity', 0.1], ...extraLeft].slice(0, 4),
    [[id, 'gate', 0.15], [id, 'trig', 0.1], [id, 'gateVelocity', 0.2], [id, 'start', 0.3], ...extraRight].slice(0, 4),
  )

const patch = (parts, voices) => {
  const out = { modules: [], cables: [] }
  for (const part of parts) {
    out.modules.push(...part.modules)
    out.cables.push(...part.cables)
  }
  if (voices) out.voices = voices
  return out
}

const every = (from, step, values, module, param) =>
  values.map((value, at) => [from + at * step, 'param', module, param, value])

export default [
  // Root source on an external clock (a pulse VCO at 130 Hz), with a sliding root, reset by an LFO,
  // through every mode, chord and octave count.
  ['players-arp-root-external', patch([
    {
      modules: [
        m('clock', 'vco', { shape: 1, tune: 12 }),
        m('root', 'lfo', { rate: 3, shape: 2 }), m('scale', 'offset', { gain: 0.5, offset: 0.2 }),
        m('reset', 'lfo', { rate: 5, shape: 3 }),
        m('arp', 'arp', { chord: 2, octaves: 2, gate: 0.6 }),
      ],
      cables: [
        c(['clock', 'out'], ['arp', 'clock']), c(['root', 'bi'], ['scale', 'in']), c(['scale', 'out'], ['arp', 'pitch']),
        c(['reset', 'uni'], ['arp', 'reset']),
      ],
    },
    arpProbe('arp'),
  ]), 192, [
    ...every(0, 32, [0, 1, 2, 3, 4, 5], 'arp', 'mode'),
    ...every(0, 8, [2, 3, 0, 1, 4, 5, 6, 7, 2, 3, 0, 1, 4, 5, 6, 7, 3, 2, 5, 4, 7, 6, 1, 0], 'arp', 'chord'),
    ...every(4, 24, [3, 4, 1, 2, 4, 1, 3, 2], 'arp', 'octaves'),
  ]],

  // Tempo timing from the transport: every division, shuffle on and off, the tempo moving, and the
  // transport's shuffle amount changing.
  ['players-arp-tempo', patch([
    {
      modules: [m('arp', 'arp', { timing: 1, division: 9, chord: 5, octaves: 3, mode: 2, shuffle: 1, gate: 0.4 })],
      cables: [],
    },
    arpProbe('arp'),
  ]), 256, [
    [0, 'transport', 400, 1, 0.6],
    ...every(0, 16, [9, 8, 7, 6, 5, 9, 8, 7, 4, 15, 14, 3, 9, 13, 8, 7], 'arp', 'division'),
    [64, 'param', 'arp', 'shuffle', 0], [96, 'param', 'arp', 'shuffle', 1],
    [100, 'transport', 333, 0, 1], [160, 'transport', 250, 1, 0.25], [200, 'transport', 400, 1, 0.9],
  ]],

  // Free timing with rate CV, the Insert modes, gate length and its CV (tie included), fixed
  // velocity and its CV, and octave shift and its CV.
  ['players-arp-free', patch([
    {
      modules: [
        m('root', 'offset', { gain: 0, offset: -0.3 }),
        m('wobble', 'lfo', { rate: 2 }), m('gatecv', 'lfo', { rate: 1.5, shape: 1 }),
        m('shiftcv', 'lfo', { rate: 2.5, shape: 2 }), m('velcv', 'lfo', { rate: 4, shape: 1 }),
        m('velscale', 'offset', { gain: 0.3 }),
        m('arp', 'arp', { timing: 2, rate: 180, chord: 4, octaves: 2, mode: 0 }),
      ],
      cables: [
        c(['root', 'out'], ['arp', 'pitch']), c(['wobble', 'bi'], ['arp', 'rateCv']), c(['gatecv', 'bi'], ['arp', 'gateCv']),
        c(['shiftcv', 'bi'], ['arp', 'shiftCv']), c(['velcv', 'bi'], ['velscale', 'in']), c(['velscale', 'out'], ['arp', 'velocityCv']),
      ],
    },
    arpProbe('arp'),
  ]), 256, [
    ...every(0, 24, [1, 2, 3, 4, 0, 3, 4, 1, 2, 4], 'arp', 'insert'),
    ...every(12, 48, [2, 3, 4, 1, 5], 'arp', 'mode'),
    [40, 'param', 'arp', 'gate', 1], [56, 'param', 'arp', 'gate', 0], [70, 'param', 'arp', 'gate', 0.8],
    [90, 'param', 'arp', 'velocityMode', 1], [110, 'param', 'arp', 'velocity', 0.35], [150, 'param', 'arp', 'velocityMode', 0],
    [120, 'param', 'arp', 'shift', 2], [170, 'param', 'arp', 'shift', -3], [200, 'param', 'arp', 'rate', 60],
    [215, 'param', 'arp', 'timing', 1], [230, 'param', 'arp', 'timing', 2],
  ]],

  // Played source, four voices: each its own pitch, velocity and gate rhythm. Through the modes
  // (Manual is note-on order), Hold latching and the Sustain pedal normalled to it, with the mod
  // input read from the first voice rather than the sum.
  ['players-arp-played-hold', patch([
    {
      modules: [
        m('notes', 'offset', { gain: 0 }), m('vels', 'offset', { gain: 0 }),
        m('keys', 'lfo', { rate: 9, shape: 3 }),
        m('pedal', 'lfo', { rate: 3, shape: 3 }), m('pedalgate', 'offset', { gain: 1, offset: -0.6 }),
        m('arp', 'arp', { source: 1, timing: 2, rate: 220, octaves: 2, gate: 0.7 }),
      ],
      cables: [
        c(['notes', 'out'], ['arp', 'pitch']), c(['vels', 'out'], ['arp', 'velocity']), c(['keys', 'uni'], ['arp', 'gate']),
        c(['notes', 'out'], ['arp', 'mod']),
        c(['pedal', 'uni'], ['pedalgate', 'in']), c(['pedalgate', 'out'], ['arp', 'sustain']),
      ],
    },
    arpProbe('arp', [['arp', 'mod', 0.2]]),
  ], 4), 256, [
    [0, 'voice', 'notes', 'offset', 0, 0], [0, 'voice', 'notes', 'offset', 0.25, 1],
    [0, 'voice', 'notes', 'offset', 0.5833, 2], [0, 'voice', 'notes', 'offset', 0.1667, 3],
    [0, 'voice', 'vels', 'offset', 0.9, 0], [0, 'voice', 'vels', 'offset', 0.4, 1],
    [0, 'voice', 'vels', 'offset', 1.3, 2], [0, 'voice', 'vels', 'offset', 0, 3],
    [0, 'voice', 'keys', 'rate', 8, 0], [0, 'voice', 'keys', 'rate', 11, 1],
    [0, 'voice', 'keys', 'rate', 13, 2], [0, 'voice', 'keys', 'rate', 17, 3],
    [60, 'voice', 'notes', 'offset', 0.25, 3],
    ...every(0, 32, [0, 5, 1, 2, 3, 4, 5, 0], 'arp', 'mode'),
    [100, 'param', 'arp', 'hold', 1], [180, 'param', 'arp', 'hold', 0], [210, 'param', 'arp', 'octaves', 4],
    // The pedal: an LFO offset down so it is only sometimes above the gate threshold.
    [120, 'param', 'pedalgate', 'offset', 0], [200, 'param', 'pedalgate', 'offset', -1],
  ]],

  // Played source with Sustain Out patched, which breaks its link to Hold; Arpeggiator Off as a
  // newest-note converter; and a switch to Root and back, which clears the latch.
  ['players-arp-played-bypass', patch([
    {
      modules: [
        m('notes', 'offset', { gain: 0 }), m('keys', 'lfo', { rate: 9, shape: 3 }),
        m('pedal', 'lfo', { rate: 6, shape: 3 }),
        m('arp', 'arp', { source: 1, timing: 2, rate: 150, octaves: 1, velocityMode: 1, velocity: 0.6, hold: 0 }),
      ],
      cables: [
        c(['notes', 'out'], ['arp', 'pitch']), c(['keys', 'uni'], ['arp', 'gate']), c(['keys', 'uni'], ['arp', 'velocity']),
        c(['pedal', 'uni'], ['arp', 'sustain']),
      ],
    },
    arpProbe('arp', [['arp', 'sustain', 0.25]]),
  ], 3), 224, [
    [0, 'voice', 'notes', 'offset', -0.25, 0], [0, 'voice', 'notes', 'offset', 0.4167, 1], [0, 'voice', 'notes', 'offset', 0.0833, 2],
    [0, 'voice', 'keys', 'rate', 7, 0], [0, 'voice', 'keys', 'rate', 10, 1], [0, 'voice', 'keys', 'rate', 15, 2],
    [40, 'param', 'arp', 'enable', 0], [90, 'param', 'arp', 'enable', 1],
    [110, 'param', 'arp', 'source', 0], [130, 'param', 'arp', 'source', 1],
    [150, 'param', 'arp', 'hold', 1], [170, 'param', 'arp', 'enable', 0], [180, 'param', 'arp', 'velocityMode', 0],
    [195, 'param', 'arp', 'enable', 1],
  ]],

  // Start patched (armed until it rises, restarting the figure), a rhythm pattern with rests from
  // patch data and then from the host, its length, Single Note Repeat off on a one-note figure, and
  // Arpeggiator Off in Root, a converter with the root's gate.
  ['players-arp-start-pattern', patch([
    {
      modules: [
        m('clock', 'vco', { shape: 1, tune: 14 }),
        m('root', 'lfo', { rate: 4, shape: 4 }), m('scale', 'offset', { gain: 0.25, offset: 0.1 }),
        m('keys', 'lfo', { rate: 20, shape: 3 }),
        m('start', 'lfo', { rate: 5, shape: 3 }), m('late', 'offset', { gain: -1, offset: 1 }),
        m('arp', 'arp', { chord: 3, octaves: 2, mode: 0, patternLength: 8, gate: 0.5 }, { data: { pattern: [1, 0, 1, 1, 0, 1, 1, 0.2] } }),
      ],
      cables: [
        c(['clock', 'out'], ['arp', 'clock']), c(['root', 'bi'], ['scale', 'in']), c(['scale', 'out'], ['arp', 'pitch']),
        c(['keys', 'uni'], ['arp', 'gate']), c(['keys', 'uni'], ['arp', 'velocity']),
        c(['start', 'uni'], ['late', 'in']), c(['late', 'out'], ['arp', 'start']),
      ],
    },
    arpProbe('arp'),
  ]), 256, [
    [60, 'param', 'arp', 'patternLength', 5],
    [90, 'data', 'arp', 'pattern', [0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0]],
    [100, 'param', 'arp', 'patternLength', 16],
    [130, 'param', 'arp', 'chord', 0], [130, 'param', 'arp', 'octaves', 1], [150, 'param', 'arp', 'singleRepeat', 0],
    [190, 'param', 'arp', 'enable', 0], [220, 'param', 'arp', 'enable', 1],
  ]],

  // Scale Player, two voices: every scale in two keys, Custom from patch data, from the host, and
  // empty (Major), and Filter mode.
  ['players-scale', patch([
    {
      modules: [
        m('sweep', 'lfo', { rate: 0.7, shape: 2 }), m('keys', 'lfo', { rate: 30, shape: 3 }), m('vels', 'lfo', { rate: 3 }),
        m('scale', 'scale-player', { key: 2 }, { data: { customScale: [1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0] } }),
      ],
      cables: [
        c(['sweep', 'bi'], ['scale', 'pitch']), c(['keys', 'uni'], ['scale', 'gate']), c(['vels', 'bi'], ['scale', 'velocity']),
      ],
    },
    probe([['scale', 'pitch', 0.2]], [['scale', 'gate', 0.2], ['scale', 'velocity', 0.15]]),
  ], 2), 256, [
    [0, 'voice', 'sweep', 'rate', 1.3, 1], [0, 'voice', 'keys', 'rate', 23, 1], [0, 'voice', 'vels', 'rate', 5, 1],
    ...every(0, 8, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 13, 13, 7], 'scale', 'scale'),
    [112, 'param', 'scale', 'key', 9], [200, 'param', 'scale', 'key', 4],
    [224, 'data', 'scale', 'customScale', [0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]],
    [232, 'data', 'scale', 'customScale', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]],
    [240, 'data', 'scale', 'customScale', [1, 1, 0.6]],
    [60, 'param', 'scale', 'filter', 1], [100, 'param', 'scale', 'filter', 0], [170, 'param', 'scale', 'filter', 1],
  ]],

  // Chord Player, two source voices of eight lanes each, a fifth apart so their chords share tones
  // and the shared tones sound once. Through notes, inversions, open voicing, the added octaves and
  // colour, Alter, the scales and Custom.
  ['players-chord', patch([
    {
      modules: [
        m('roots', 'offset', { gain: 0 }), m('bend', 'lfo', { rate: 0.9, shape: 1 }), m('bendscale', 'offset', { gain: 0.04 }),
        m('pitch', 'mixer'),
        m('keys', 'lfo', { rate: 25, shape: 3 }), m('vels', 'offset', { gain: 0 }),
        m('chord', 'chord-player', {}, { data: { customScale: [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0] } }),
      ],
      cables: [
        c(['bend', 'bi'], ['bendscale', 'in']), c(['roots', 'out'], ['pitch', 'in1']), c(['bendscale', 'out'], ['pitch', 'in2']),
        c(['pitch', 'out'], ['chord', 'pitch']), c(['keys', 'uni'], ['chord', 'gate']), c(['vels', 'out'], ['chord', 'velocity']),
      ],
    },
    probe([['chord', 'pitch', 0.01]], [['chord', 'gate', 0.04], ['chord', 'velocity', 0.03]]),
  ], 2), 256, [
    [0, 'voice', 'roots', 'offset', 0.1667, 0], [0, 'voice', 'roots', 'offset', 0.75, 1],
    [0, 'voice', 'vels', 'offset', 0.8, 0], [0, 'voice', 'vels', 'offset', 1.4, 1],
    [0, 'voice', 'keys', 'rate', 19, 1],
    ...every(0, 16, [3, 1, 2, 4, 5, 3, 5, 4, 3, 2, 5, 3, 4, 5, 3, 1], 'chord', 'notes'),
    ...every(8, 16, [1, 2, 3, 4, 0, 2, 4, 1, 3, 0, 4, 2, 1, 3, 0], 'chord', 'inversion'),
    [30, 'param', 'chord', 'open', 1], [70, 'param', 'chord', 'open', 0], [150, 'param', 'chord', 'open', 1],
    [50, 'param', 'chord', 'octUp', 1], [90, 'param', 'chord', 'octDown', 1], [110, 'param', 'chord', 'color', 1],
    [130, 'param', 'chord', 'octUp', 0], [140, 'param', 'chord', 'alter', 1], [190, 'param', 'chord', 'octDown', 0],
    [210, 'param', 'chord', 'alter', 0],
    ...every(0, 20, [0, 1, 4, 7, 9, 11, 13, 2, 5, 10, 12, 13, 3], 'chord', 'scale'),
    [100, 'param', 'chord', 'key', 5], [180, 'param', 'chord', 'key', 10],
    [245, 'data', 'chord', 'customScale', [0, 0, 0]],
  ]],

  // The widest a stream may be: eight voices of eight lanes, and a second Chord Player after it that
  // cannot expand again. Heard through oscillators, as it would be played.
  ['players-chord-wide', patch([
    {
      modules: [
        m('roots', 'offset', { gain: 0 }), m('keys', 'lfo', { rate: 12, shape: 3 }),
        m('chord', 'chord-player', { notes: 4, color: 1 }), m('again', 'chord-player', { notes: 2, key: 3, scale: 1 }),
        m('osc', 'vco', { shape: 2 }), m('amp', 'vca', { gain: 0.02 }),
      ],
      cables: [
        c(['roots', 'out'], ['chord', 'pitch']), c(['keys', 'uni'], ['chord', 'gate']), c(['keys', 'uni'], ['chord', 'velocity']),
        c(['chord', 'pitch'], ['again', 'pitch']), c(['chord', 'gate'], ['again', 'gate']), c(['chord', 'velocity'], ['again', 'velocity']),
        c(['again', 'pitch'], ['osc', 'pitch']), c(['osc', 'out'], ['amp', 'in']), c(['again', 'gate'], ['amp', 'cv']),
      ],
    },
    probe([['amp', 'out', 1]], [['again', 'gate', 0.01], ['chord', 'velocity', 0.01]]),
  ], 8), 48, [
    ...[0, 0.0833, 0.1667, 0.25, 0.3333, 0.4167, 0.5, 0.5833].map((value, voice) => [0, 'voice', 'roots', 'offset', value, voice]),
    ...[5, 6, 7, 8, 9, 10, 11, 12].map((rate, voice) => [0, 'voice', 'keys', 'rate', rate * 3, voice]),
    [24, 'param', 'chord', 'notes', 5], [24, 'param', 'chord', 'octDown', 1],
  ]],

  // A Chord Player's lanes collected by a played Arp, the pairing the two exist for.
  ['players-chord-arp', patch([
    {
      modules: [
        m('roots', 'offset', { gain: 0 }), m('keys', 'lfo', { rate: 6, shape: 3 }),
        m('chord', 'chord-player', { notes: 4, octUp: 1 }),
        m('arp', 'arp', { source: 1, timing: 2, rate: 240, octaves: 2, mode: 2 }),
      ],
      cables: [
        c(['roots', 'out'], ['chord', 'pitch']), c(['keys', 'uni'], ['chord', 'gate']), c(['keys', 'uni'], ['chord', 'velocity']),
        c(['chord', 'pitch'], ['arp', 'pitch']), c(['chord', 'gate'], ['arp', 'gate']), c(['chord', 'velocity'], ['arp', 'velocity']),
      ],
    },
    arpProbe('arp'),
  ], 2), 160, [
    [0, 'voice', 'roots', 'offset', 0, 0], [0, 'voice', 'roots', 'offset', 0.3333, 1], [0, 'voice', 'keys', 'rate', 4, 1],
    [50, 'param', 'arp', 'mode', 5], [90, 'param', 'arp', 'mode', 4], [120, 'param', 'chord', 'inversion', 2],
  ]],
]
