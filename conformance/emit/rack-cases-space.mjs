// The Space family's rack cases: ping-pong, phaser, reverb and looper, fed by the core modules.
// Each is [name, patch, blocks, events?, hostBuses?], in the shape `emit.mjs` describes.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

// A plucked pulse: a square clock gating a short envelope over a VCA. The spine of most cases here.
const pluck = (rate, tune = 0, shape = 1) => ({
  modules: [
    m('clock', 'lfo', { rate, shape: 3 }),
    m('env', 'adsr', { attack: 0.001, decay: 0.04, sustain: 0, release: 0.01 }),
    m('osc', 'vco', { shape, tune }),
    m('amp', 'vca', { gain: 0 }),
  ],
  cables: [
    c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']),
  ],
})

const patch = (source, modules, cables) => ({
  modules: [...source.modules, ...modules],
  cables: [...source.cables, ...cables],
})

export default [
  // Bouncing repeats with high cross feedback, then a shorter time and the feedback at its ceiling.
  ['space-ping-pong-bounce', patch(pluck(3), [m('echo', 'ping-pong', { time: 0.05, feedback: 0.7 }), m('out', 'out', { level: 1 })], [
    c(['amp', 'out'], ['echo', 'in']), c(['echo', 'out'], ['out', 'in']),
  ]), 96, [[40, 'param', 'echo', 'time', 0.031], [64, 'param', 'echo', 'feedback', 0.98]]],

  // The shortest time, swept in octaves from an LFO, feedback from a cable past its clamp, and a hot
  // continuous input that drives the lines into their ±8 limit.
  ['space-ping-pong-cv', {
    modules: [
      m('osc', 'vco', { tune: 5 }), m('hot', 'mixer', { level1: 2 }), m('sweep', 'lfo', { rate: 9 }),
      m('fbmod', 'lfo', { rate: 3, shape: 1 }), m('echo', 'ping-pong', { time: 0.0003, feedback: 0.9 }),
      m('out', 'out', { level: 0.1 }),
    ],
    cables: [
      c(['osc', 'out'], ['hot', 'in1']), c(['hot', 'out'], ['echo', 'in']), c(['sweep', 'bi'], ['echo', 'time']),
      c(['fbmod', 'uni'], ['echo', 'fb']), c(['echo', 'out'], ['out', 'in']),
    ],
  }, 64, [[32, 'param', 'echo', 'time', 0.004]]],

  // Defaults on a mono saw, centred into both sides and opened by the quarter-cycle offset.
  ['space-phaser-default', {
    modules: [m('osc', 'vco', { tune: -12 }), m('phase', 'phaser'), m('out', 'out')],
    cables: [c(['osc', 'out'], ['phase', 'in']), c(['phase', 'out'], ['out', 'in'])],
  }, 64],

  // A genuinely stereo input (a ping-pong's), the fastest rate at full depth, negative feedback at its
  // floor, wet only, and the Sweep inlet driven; then feedback to its ceiling and the centre down.
  ['space-phaser-extremes', patch(pluck(7, 0, 0), [
    m('echo', 'ping-pong', { time: 0.02, feedback: 0.5 }), m('hiss', 'noise'), m('bed', 'mixer', { level1: 1, level2: 0.2 }),
    m('sweep', 'lfo', { rate: 13, shape: 2 }),
    m('phase', 'phaser', { rate: 8, center: 4000, depth: 1, feedback: -0.9, mix: 1 }), m('out', 'out'),
  ], [
    c(['amp', 'out'], ['bed', 'in1']), c(['hiss', 'pink'], ['bed', 'in2']), c(['bed', 'out'], ['echo', 'in']),
    c(['echo', 'out'], ['phase', 'in']), c(['sweep', 'bi'], ['phase', 'sweep']), c(['phase', 'out'], ['out', 'in']),
  ]), 80, [[40, 'param', 'phase', 'feedback', 0.9], [40, 'param', 'phase', 'center', 80], [60, 'param', 'phase', 'mix', 0.3]]],

  // Room, the original network, half wet; the damping swept dark then open partway through the tail.
  ['space-reverb-room', patch(pluck(2.5), [m('room', 'reverb', { mix: 0.5 }), m('out', 'out', { level: 1 })], [
    c(['amp', 'out'], ['room', 'in']), c(['room', 'out'], ['out', 'in']),
  ]), 180, [[60, 'param', 'room', 'damp', 0.99], [120, 'param', 'room', 'damp', 0], [120, 'param', 'room', 'size', 0.1]]],

  // Hall's diffusion on a long, small-sized tail, switched to Plate mid-tail.
  ['space-reverb-hall-plate', patch(pluck(3, 7), [
    m('hall', 'reverb', { algorithm: 1, size: 0.4, decay: 0.95, damp: 0.2, mix: 0.7 }), m('out', 'out', { level: 1 }),
  ], [
    c(['amp', 'out'], ['hall', 'in']), c(['hall', 'out'], ['out', 'in']),
  ]), 180, [[90, 'param', 'hall', 'algorithm', 2], [140, 'param', 'hall', 'decay', 0.98]]],

  // Spring's dispersion under both EQ halves, which are then opened back to off.
  ['space-reverb-spring-eq', patch(pluck(4, -5, 0), [
    m('spring', 'reverb', { algorithm: 3, size: 1, decay: 0.9, mix: 0.8, lowCut: 300, highCut: 4000 }),
    m('out', 'out', { level: 1 }),
  ], [
    c(['amp', 'out'], ['spring', 'in']), c(['spring', 'out'], ['out', 'in']),
  ]), 160, [[80, 'param', 'spring', 'lowCut', 20], [80, 'param', 'spring', 'highCut', 18000], [120, 'param', 'spring', 'lowCut', 2000]]],

  // The gate keyed from the input on a Plate: bursts open it, hold and release close it, and switching
  // it off and on mid-tail reopens it.
  ['space-reverb-gate', patch(pluck(3), [
    m('gated', 'reverb', { algorithm: 2, decay: 0.95, mix: 1, gate: 1, gateThresh: 0.1, gateHold: 0.05, gateRelease: 0.03 }),
    m('out', 'out', { level: 1 }),
  ], [
    c(['amp', 'out'], ['gated', 'in']), c(['gated', 'out'], ['out', 'in']),
  ]), 160, [[70, 'param', 'gated', 'gate', 0], [90, 'param', 'gated', 'gate', 1], [100, 'param', 'gated', 'gateRelease', 0.5], [100, 'param', 'gated', 'gateHold', 0]]],

  // Record a stereo take, close it into Play, then change the source so the loop and the dry differ.
  // The rack's transport is started and stopped as well; the looper follows its own knob, not it.
  ['space-looper-rec-play', patch(pluck(5, 0, 0), [
    m('echo', 'ping-pong', { time: 0.03, feedback: 0.6 }), m('bed', 'mixer', { level1: 0.6, level2: 0.8 }),
    m('loop', 'looper', { dry: 0.5 }), m('out', 'out', { level: 1 }),
  ], [
    c(['amp', 'out'], ['bed', 'in1']), c(['amp', 'out'], ['echo', 'in']), c(['echo', 'out'], ['loop', 'in']),
    c(['bed', 'out'], ['loop', 'in']), c(['loop', 'out'], ['out', 'in']),
  ]), 96, [
    [0, 'transport', 120, 1, 0], [4, 'param', 'loop', 'mode', 1], [30, 'param', 'loop', 'mode', 2],
    [30, 'param', 'osc', 'tune', 7], [50, 'transport', 120, 0, 0], [60, 'param', 'loop', 'loop', 0.4],
    [70, 'param', 'loop', 'mode', 0], [80, 'param', 'loop', 'mode', 2],
  ]],

  // Dub on an empty pedal makes the first pass; overdub with feedback; clear while playing; record a
  // fresh take; stop and play again.
  ['space-looper-dub-clear', patch(pluck(6, -7), [
    m('phase', 'phaser', { rate: 2, mix: 0.6 }), m('loop', 'looper', { mode: 3, feedback: 0.5, dry: 0.3 }),
    m('out', 'out', { level: 1 }),
  ], [
    c(['amp', 'out'], ['phase', 'in']), c(['phase', 'out'], ['loop', 'in']), c(['loop', 'out'], ['out', 'in']),
  ]), 120, [
    [16, 'param', 'loop', 'mode', 2], [24, 'param', 'loop', 'mode', 3], [24, 'param', 'osc', 'tune', 5],
    [48, 'param', 'loop', 'mode', 2], [60, 'param', 'loop', 'clear', 1], [66, 'param', 'loop', 'mode', 1],
    [80, 'param', 'loop', 'mode', 2], [96, 'param', 'loop', 'clear', 0], [100, 'param', 'loop', 'mode', 3],
    [100, 'param', 'loop', 'feedback', 1], [110, 'param', 'loop', 'mode', 2],
  ]],
]
