// The control family's rack cases: follower, quantizer, meter, tuner, line mixer and Combinator,
// in the shape `emit.mjs` describes. The Combinator's cases carry `modulation` routes, so the
// compiled plan's param values are held to the reference as well as the sound.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })
const route = (from, to, min, max) => ({ from, to, ...(min !== undefined ? { min } : {}), ...(max !== undefined ? { max } : {}) })

export default [
  // A plucked VCO followed: its envelope opens a filter on noise, and its gate clicks into the mix.
  ['control-follower-filter', {
    modules: [
      m('clock', 'lfo', { rate: 5, shape: 3 }), m('env', 'adsr', { attack: 0.002, decay: 0.08, sustain: 0.1, release: 0.05 }),
      m('osc', 'vco', { shape: 1 }), m('amp', 'vca', { gain: 0 }),
      m('follow', 'follower', { attack: 0.003, release: 0.08, gain: 3, threshold: 0.3 }),
      m('hiss', 'noise'), m('filter', 'svf', { cutoff: 300, resonance: 0.6 }),
      m('mix', 'mixer', { level1: 0.5, level2: 0.8, level3: 0.1 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']),
      c(['amp', 'out'], ['follow', 'in']), c(['hiss', 'white'], ['filter', 'in']), c(['follow', 'env'], ['filter', 'cutoff']),
      c(['amp', 'out'], ['mix', 'in1']), c(['filter', 'lp'], ['mix', 'in2']), c(['follow', 'gate'], ['mix', 'in3']),
      c(['mix', 'out'], ['out', 'in']),
    ],
  }, 64],
  // The follower's own outlets, straight out, with its knobs moved mid-render: a hot gain that the
  // outlet clamps at 4, and a threshold the gate sits on.
  ['control-follower-knobs', {
    modules: [
      m('wobble', 'lfo', { rate: 3, shape: 1 }), m('osc', 'vco', { tune: 5 }), m('amp', 'vca', { gain: 0 }),
      m('follow', 'follower', { attack: 0.0005, release: 0.0005, gain: 8, threshold: 1.2 }),
      m('mix', 'mixer', { level1: 0.2, level2: 0.3 }), m('out', 'out'),
    ],
    cables: [
      c(['osc', 'out'], ['amp', 'in']), c(['wobble', 'uni'], ['amp', 'cv']), c(['amp', 'out'], ['follow', 'in']),
      c(['follow', 'env'], ['mix', 'in1']), c(['follow', 'gate'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 48, [
    [12, 'param', 'follow', 'attack', 0.2], [12, 'param', 'follow', 'release', 1.5],
    [24, 'param', 'follow', 'gain', 1], [24, 'param', 'follow', 'threshold', 0.25],
    [36, 'schedule', 'follow', 'threshold', 0.05, 36 * 128 + 50], [40, 'param', 'follow', 'attack', 0.01],
  ]],
  // Noise through a sample and hold into a quantizer: random voltage as a melody, each new note
  // striking an envelope from the quantizer's trig.
  ['control-quantizer-melody', {
    modules: [
      m('hiss', 'noise'), m('clock', 'lfo', { rate: 9, shape: 3 }), m('hold', 'sample-hold'),
      m('snap', 'quantizer', { scale: 2, root: 9 }), m('env', 'adsr', { attack: 0.001, decay: 0.05, sustain: 0.3, release: 0.02 }),
      m('osc', 'vco'), m('amp', 'vca', { gain: 0 }), m('out', 'out'),
    ],
    cables: [
      c(['hiss', 'white'], ['hold', 'in']), c(['clock', 'uni'], ['hold', 'trig']), c(['hold', 'out'], ['snap', 'in']),
      c(['snap', 'out'], ['osc', 'pitch']), c(['snap', 'trig'], ['env', 'trig']), c(['osc', 'out'], ['amp', 'in']),
      c(['env', 'out'], ['amp', 'cv']), c(['amp', 'out'], ['out', 'in']),
    ],
  }, 64],
  // A slow bipolar ramp through every scale and several roots, the quantized pitch and the trig
  // both heard, so negative octaves and the octave-above root are exercised across the range.
  ['control-quantizer-scales', {
    modules: [
      m('sweep', 'lfo', { rate: 1.3, shape: 2 }), m('span', 'offset', { gain: 1.7, offset: 0.1 }),
      m('snap', 'quantizer', { scale: 0 }), m('osc', 'vco', { shape: 2 }), m('mix', 'mixer', { level1: 0.4, level2: 0.3, level3: 0.3 }), m('out', 'out'),
    ],
    cables: [
      c(['sweep', 'bi'], ['span', 'in']), c(['span', 'out'], ['snap', 'in']), c(['snap', 'out'], ['osc', 'pitch']),
      c(['osc', 'out'], ['mix', 'in1']), c(['snap', 'trig'], ['mix', 'in2']), c(['snap', 'out'], ['mix', 'in3']),
      c(['mix', 'out'], ['out', 'in']),
    ],
  }, 96, [
    [16, 'param', 'snap', 'scale', 1], [32, 'param', 'snap', 'scale', 2], [32, 'param', 'snap', 'root', 4],
    [48, 'param', 'snap', 'scale', 3], [64, 'param', 'snap', 'scale', 4], [64, 'param', 'snap', 'root', 11],
    [80, 'param', 'snap', 'scale', 5], [88, 'param', 'snap', 'root', 1],
  ]],
  // Pitches exactly halfway between two degrees, from a constant: the lower degree wins a tie,
  // as the reference's strict comparison has it, in several scales and across octaves.
  ['control-quantizer-ties', {
    modules: [
      m('pitch', 'offset', { gain: 0, offset: 0.25 }), m('snap', 'quantizer', { scale: 1 }),
      m('osc', 'vco', { shape: 2 }), m('mix', 'mixer', { level1: 0.5, level2: 0.4, level3: 0.2 }), m('out', 'out'),
    ],
    cables: [
      c(['pitch', 'out'], ['snap', 'in']), c(['snap', 'out'], ['osc', 'pitch']), c(['osc', 'out'], ['mix', 'in1']),
      c(['snap', 'out'], ['mix', 'in2']), c(['snap', 'trig'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
    ],
  }, 48, [
    [4, 'param', 'pitch', 'offset', 0.5], [8, 'param', 'snap', 'scale', 5], [8, 'param', 'pitch', 'offset', -0.75],
    [12, 'param', 'snap', 'scale', 0], [12, 'param', 'pitch', 'offset', 0.125], [16, 'param', 'pitch', 'offset', -1.375],
    [20, 'param', 'snap', 'scale', 3], [20, 'param', 'pitch', 'offset', 0.375], [24, 'param', 'pitch', 'offset', 0.5],
    [28, 'param', 'snap', 'scale', 4], [28, 'param', 'snap', 'root', 3], [28, 'param', 'pitch', 'offset', 0.625],
    [32, 'param', 'snap', 'scale', 2], [32, 'param', 'pitch', 'offset', 1.125], [36, 'param', 'snap', 'root', 7],
    [40, 'param', 'pitch', 'offset', -0.625], [44, 'param', 'snap', 'scale', 1], [44, 'param', 'pitch', 'offset', 0.9375],
  ]],
  // A meter in a cable: Thru to the output, and its envelope heard beside it, with its
  // sensitivity and release turned mid-render.
  ['control-meter-thru', {
    modules: [
      m('clock', 'lfo', { rate: 4, shape: 3 }), m('env', 'adsr', { attack: 0.001, decay: 0.1, sustain: 0.2, release: 0.1 }),
      m('osc', 'vco', { tune: -3 }), m('amp', 'vca', { gain: 0 }), m('watch', 'meter', { gain: 2, release: 0.1 }),
      m('mix', 'mixer', { level1: 0.6, level2: 0.25 }), m('out', 'out'),
    ],
    cables: [
      c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']),
      c(['amp', 'out'], ['watch', 'in']), c(['watch', 'thru'], ['mix', 'in1']), c(['watch', 'env'], ['mix', 'in2']),
      c(['mix', 'out'], ['out', 'in']),
    ],
  }, 64, [[20, 'param', 'watch', 'release', 1.2], [36, 'param', 'watch', 'gain', 4], [48, 'param', 'watch', 'release', 0.05]]],
  // A meter's envelope used as the CV it is: a loud pulse wave, watched, opening a VCA on a drone.
  ['control-meter-env-vca', {
    voices: 2,
    modules: [
      m('wobble', 'lfo', { rate: 2, shape: 0 }), m('osc', 'vco', { shape: 1, tune: -12 }), m('amp', 'vca', { gain: 0 }),
      m('watch', 'meter', { gain: 0.5, release: 0.4 }), m('drone', 'vco', { shape: 2, tune: 7 }), m('gate', 'vca', { gain: 0 }),
      m('out', 'out'),
    ],
    cables: [
      c(['osc', 'out'], ['amp', 'in']), c(['wobble', 'uni'], ['amp', 'cv']), c(['amp', 'out'], ['watch', 'in']),
      c(['drone', 'out'], ['gate', 'in']), c(['watch', 'env'], ['gate', 'cv']), c(['gate', 'out'], ['out', 'in']),
    ],
  }, 48, [[0, 'voice', 'osc', 'tune', -5, 1]]],
  // A tuner is transparent until muted, and transparent again after.
  ['control-tuner-mute', {
    modules: [m('osc', 'vco', { tune: 9 }), m('tune', 'tuner'), m('out', 'out')],
    cables: [c(['osc', 'out'], ['tune', 'in']), c(['tune', 'thru'], ['out', 'in'])],
  }, 32, [[8, 'param', 'tune', 'mute', 1], [16, 'param', 'tune', 'reference', 432], [20, 'param', 'tune', 'mute', 0]]],
  // A tuner on noise into a feedback loop through a filter: what it passes is still exactly what
  // arrives, whatever arrives.
  ['control-tuner-noise', {
    modules: [
      m('hiss', 'noise'), m('mix', 'mixer', { level1: 0.4, level2: 0.9 }), m('filter', 'svf', { cutoff: 900, resonance: 0.8 }),
      m('tune', 'tuner', { reference: 415 }), m('out', 'out'),
    ],
    cables: [
      c(['hiss', 'pink'], ['mix', 'in1']), c(['tune', 'thru'], ['mix', 'in2']), c(['mix', 'out'], ['filter', 'in']),
      c(['filter', 'bp'], ['tune', 'in']), c(['tune', 'thru'], ['out', 'in']),
    ],
  }, 32],
  // Three sources on a desk: a mono VCO, stereo noise through an Out, a triangle panned hard, with
  // levels and balance set and the master riding.
  ['control-line-mixer-channels', {
    modules: [
      m('saw', 'vco', { tune: -12 }), m('hiss', 'noise'), m('spread', 'out', { level: 0.5, pan: 0.4 }), m('tri', 'vco', { shape: 2, tune: 7 }),
      m('desk', 'line-mixer', { level1: 0.9, pan1: -0.5, level2: 0.4, pan2: 0.3, level3: 1, pan3: 1, pan4: -1, master: 1.2 }),
      m('out', 'out', { level: 0.8 }),
    ],
    cables: [
      c(['saw', 'out'], ['desk', 'in1']), c(['hiss', 'pink'], ['spread', 'in']), c(['spread', 'out'], ['desk', 'in2']),
      c(['tri', 'out'], ['desk', 'in3']), c(['saw', 'out'], ['desk', 'in4']), c(['desk', 'out'], ['out', 'in']),
    ],
  }, 32, [[10, 'param', 'desk', 'pan3', -0.7], [16, 'param', 'desk', 'master', 0.6], [22, 'param', 'desk', 'level4', 0.3]]],
  // Both sends round an effect and back to their returns: A through a delay, B through a filter,
  // with the returns' levels, a mute and a solo moved, including a solo dropped mid-block.
  ['control-line-mixer-sends', {
    modules: [
      m('clock', 'lfo', { rate: 6, shape: 3 }), m('env', 'adsr', { attack: 0.001, decay: 0.04, sustain: 0, release: 0.01 }),
      m('osc', 'vco', { shape: 1 }), m('amp', 'vca', { gain: 0 }), m('drone', 'vco', { shape: 2, tune: -5 }), m('hiss', 'noise'),
      m('desk', 'line-mixer', { level1: 0.8, sendA1: 0.7, sendB1: 0.2, level2: 0.3, pan2: 0.6, sendA2: 0.1, sendB2: 0.9, level3: 0.2, pan3: -0.8, sendB3: 0.5, returnLevelA: 0.8, returnLevelB: 1.3 }),
      m('echo', 'delay', { time: 0.07, feedback: 0.5 }), m('tone', 'svf', { cutoff: 1500, resonance: 0.7 }),
      m('out', 'out', { level: 0.6 }),
    ],
    cables: [
      c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']),
      c(['amp', 'out'], ['desk', 'in1']), c(['drone', 'out'], ['desk', 'in2']), c(['hiss', 'white'], ['desk', 'in3']),
      c(['desk', 'sendA'], ['echo', 'in']), c(['echo', 'out'], ['desk', 'returnA']),
      c(['desk', 'sendB'], ['tone', 'in']), c(['tone', 'bp'], ['desk', 'returnB']),
      c(['desk', 'out'], ['out', 'in']),
    ],
  }, 64, [
    [16, 'param', 'desk', 'mute3', 1], [24, 'param', 'desk', 'solo2', 1], [32, 'schedule', 'desk', 'solo2', 0, 33 * 128 + 71],
    [40, 'param', 'desk', 'solo1', 1], [40, 'param', 'desk', 'solo3', 1], [48, 'param', 'desk', 'mute1', 1], [56, 'param', 'desk', 'returnLevelA', 0],
  ]],
  // The desk's sends heard directly on Outs of their own, pre-master, beside the main pair.
  ['control-line-mixer-send-outs', {
    modules: [
      m('saw', 'vco'), m('tri', 'vco', { shape: 2, tune: 12 }),
      m('desk', 'line-mixer', { level1: 0.5, pan1: 0.9, sendA1: 1, sendB1: 0.25, level2: 0.7, pan2: -0.2, sendA2: 0.4, sendB2: 0.8, master: 0.3 }),
      m('main', 'out', { level: 1 }), m('a', 'out', { level: 0.5, pan: -0.5 }), m('b', 'out', { level: 0.5 }),
    ],
    cables: [
      c(['saw', 'out'], ['desk', 'in1']), c(['tri', 'out'], ['desk', 'in2']),
      c(['desk', 'out'], ['main', 'in']), c(['desk', 'sendA'], ['a', 'in']), c(['desk', 'sendB'], ['b', 'in']),
    ],
  }, 24, [[12, 'param', 'desk', 'master', 1.5]]],
  // Combinator routes, compiled into the params: a rotary across a filter's cutoff, one across a
  // stepped shape landing on a half (rounded up), an inverted route, a button, and a route whose
  // range overshoots the target's and is clamped. The Combinator's outlets are heard too.
  ['control-combi-routes', {
    modules: [
      m('macro', 'combi', { rotary1: 100, rotary2: 31.75, rotary3: 20, button1: 1 }),
      m('osc', 'vco', { tune: -12 }), m('filter', 'svf'), m('amp', 'vca'), m('wobble', 'lfo'),
      m('mix', 'mixer', { level1: 0.7, level2: 0.1, level3: 0.1 }), m('out', 'out'),
    ],
    cables: [
      c(['osc', 'out'], ['filter', 'in']), c(['filter', 'lp'], ['amp', 'in']), c(['wobble', 'bi'], ['osc', 'fm']),
      c(['amp', 'out'], ['mix', 'in1']), c(['macro', 'rotary1'], ['mix', 'in2']), c(['macro', 'button1'], ['mix', 'in3']),
      c(['mix', 'out'], ['out', 'in']),
    ],
    modulation: [
      route(['macro', 'rotary1'], ['filter', 'cutoff'], 200, 4000),
      route(['macro', 'rotary2'], ['osc', 'shape']),
      route(['macro', 'rotary3'], ['amp', 'gain'], 1, 0.2),
      route(['macro', 'button1'], ['filter', 'resonance'], 0.1, 0.9),
      route(['macro', 'rotary1'], ['wobble', 'rate'], -10, 90),
    ],
  }, 24],
  // Chains and contests: one Combinator driving another's rotary, which then drives a ladder;
  // two routes onto one target (the later wins); a route from an ADSR's sustain rather than a
  // Combinator; routes naming a module, a param and a source that do not exist, all skipped; and
  // an untouched rotary resting at 64.
  ['control-combi-chains', {
    modules: [
      m('outer', 'combi', { rotary1: 127, rotary2: 0 }), m('inner', 'combi'),
      m('env', 'adsr', { sustain: 0.25 }), m('osc', 'vco', { shape: 1 }), m('filter', 'ladder'), m('wobble', 'lfo'),
      m('out', 'out'),
    ],
    cables: [
      c(['osc', 'out'], ['filter', 'in']), c(['wobble', 'bi'], ['filter', 'cutoff']), c(['filter', 'out'], ['out', 'in']),
    ],
    modulation: [
      route(['outer', 'rotary1'], ['inner', 'rotary2'], 10, 100),
      route(['inner', 'rotary2'], ['filter', 'cutoff'], 100, 3000),
      route(['inner', 'rotary1'], ['filter', 'resonance'], 0, 1),
      route(['outer', 'rotary2'], ['filter', 'resonance'], 0.9, 0.3),
      route(['env', 'sustain'], ['wobble', 'rate'], 0, 16),
      route(['inner', 'rotary3'], ['osc', 'width'], 0.1, 0.9),
      route(['outer', 'rotary1'], ['ghost', 'cutoff']),
      route(['outer', 'rotary1'], ['filter', 'nothing']),
      route(['ghost', 'rotary1'], ['osc', 'tune']),
      route(['outer', 'nothing'], ['osc', 'tune']),
    ],
  }, 24],
  // The Combinator as a panel of CV: rotaries and buttons turned mid-render reach the outlets
  // through the graph's ramps, and a routing is not re-applied by a knob turn.
  ['control-combi-outlets', {
    modules: [
      m('macro', 'combi', { rotary1: 0, rotary2: 127, rotary3: 64 }), m('osc', 'vco'), m('amp', 'vca', { gain: 0 }),
      m('mix', 'mixer', { level1: 1, level2: 0.2, level3: 0.2, level4: 0.2 }), m('out', 'out'),
    ],
    cables: [
      c(['osc', 'out'], ['amp', 'in']), c(['macro', 'rotary1'], ['amp', 'cv']), c(['amp', 'out'], ['mix', 'in1']),
      c(['macro', 'rotary2'], ['mix', 'in2']), c(['macro', 'button2'], ['mix', 'in3']), c(['macro', 'rotary3'], ['mix', 'in4']),
      c(['mix', 'out'], ['out', 'in']),
    ],
    modulation: [route(['macro', 'rotary3'], ['osc', 'tune'], -12, 12)],
  }, 32, [
    [4, 'param', 'macro', 'rotary1', 90], [8, 'param', 'macro', 'button2', 1], [12, 'schedule', 'macro', 'rotary2', 20, 12 * 128 + 40],
    [16, 'param', 'macro', 'rotary3', 127], [20, 'param', 'macro', 'button2', 0], [24, 'param', 'macro', 'rotary1', 127],
  ]],
]
