// The sequencing family's rack cases: transport, clock, seq, tracker, arranger, midi and note echo.
// Each drives a voice — a VCO through an envelope and a VCA — from the sequencer's pitch and gate,
// so the render proves the timing, and mixes the raw control outlets in beside it so a step that
// lands a sample late shows up as a difference rather than hiding under an envelope.

const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
const c = (from, to) => ({ from, to })

/** A VCO, an ADSR and a VCA, with the VCA out mixed into `mix` at `input`. */
const voice = (prefix, mix, input, env = {}, osc = {}) => ({
  modules: [
    m(`${prefix}osc`, 'vco', { shape: 1, ...osc }),
    m(`${prefix}env`, 'adsr', { attack: 0.002, decay: 0.04, sustain: 0.4, release: 0.03, ...env }),
    m(`${prefix}amp`, 'vca', { gain: 0 }),
  ],
  cables: [
    c([`${prefix}osc`, 'out'], [`${prefix}amp`, 'in']),
    c([`${prefix}env`, 'out'], [`${prefix}amp`, 'cv']),
    c([`${prefix}amp`, 'out'], [mix, input]),
  ],
})

const join = (...parts) => ({
  ...Object.assign({}, ...parts),
  modules: parts.flatMap((part) => part.modules),
  cables: parts.flatMap((part) => part.cables),
})

export default [
  // Every outlet of the transport, in three: the ramps and the divisions straight into the mix,
  // and the sixteenths striking a voice whose pitch rides the bar ramp.
  ['sequencing-transport-divisions', join(
    {
      modules: [
        m('tx', 'transport', { beatsPerBar: 3 }),
        m('mix', 'mixer', { level1: 0.5, level2: 0.2, level3: 0.2, level4: 0.3 }),
        m('ticks', 'mixer', { level1: 0.1, level2: 0.15, level3: 0.2, level4: 0.05 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'sixteenth'], ['env', 'gate']), c(['tx', 'bar'], ['osc', 'pitch']),
        c(['tx', 'bar'], ['mix', 'in2']), c(['tx', 'beat'], ['mix', 'in3']),
        c(['tx', 'quarter'], ['ticks', 'in1']), c(['tx', 'eighth'], ['ticks', 'in2']),
        c(['tx', 'sixteenth'], ['ticks', 'in3']), c(['tx', 'run'], ['ticks', 'in4']),
        c(['ticks', 'out'], ['mix', 'in4']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { attack: 0.001, decay: 0.02, sustain: 0 }),
  ), 160, [[0, 'transport', 300, 1, 0], [90, 'param', 'tx', 'beatsPerBar', 7]]],

  // Stopped at first, started at block 6, the tempo changed while running, stopped (the ramps hold
  // still), and started again (which rewinds to bar one and fires the downbeat).
  ['sequencing-transport-tempo-stop', join(
    {
      modules: [
        m('tx', 'transport'),
        m('mix', 'mixer', { level1: 0.5, level2: 0.25, level3: 0.25, level4: 0.2 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'eighth'], ['env', 'gate']), c(['tx', 'beat'], ['osc', 'pitch']),
        c(['tx', 'bar'], ['mix', 'in2']), c(['tx', 'beat'], ['mix', 'in3']), c(['tx', 'quarter'], ['mix', 'in4']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.03, sustain: 0.2 }),
  ), 200, [
    [0, 'transport', 180, 0, 0], [6, 'transport', 240, 1, 0.5], [50, 'transport', 397, 1, 0.5],
    [100, 'transport', 397, 0, 0], [130, 'transport', 133, 1, 0.25], [170, 'transport', 400, 1, 1],
  ]],

  // A free clock at a rate a cable sweeps, its gate holding an envelope open, its trigger and phase
  // mixed in, and its width turned mid-render.
  ['sequencing-clock-rate-width', join(
    {
      modules: [
        m('clk', 'clock', { rate: 37, width: 0.3 }),
        m('sweep', 'lfo', { rate: 3, shape: 1 }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.2, level3: 0.3 }),
        m('out', 'out'),
      ],
      cables: [
        c(['sweep', 'bi'], ['clk', 'rate']), c(['clk', 'gate'], ['env', 'gate']), c(['clk', 'phase'], ['osc', 'pitch']),
        c(['clk', 'trig'], ['mix', 'in2']), c(['clk', 'phase'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1'),
  ), 120, [[40, 'param', 'clk', 'width', 0.85], [80, 'param', 'clk', 'rate', 90]]],

  // A clock reset by the transport's quarter notes: every reset fires a beat and restarts the ramp.
  ['sequencing-clock-reset', join(
    {
      modules: [
        m('tx', 'transport'),
        m('clk', 'clock', { rate: 11, width: 0.5 }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.3, level3: 0.3 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'quarter'], ['clk', 'reset']), c(['clk', 'trig'], ['env', 'trig']), c(['clk', 'phase'], ['osc', 'pitch']),
        c(['clk', 'gate'], ['mix', 'in2']), c(['clk', 'phase'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.02, sustain: 0 }),
  ), 160, [[0, 'transport', 410, 1, 0], [70, 'param', 'clk', 'rate', 23]]],

  // Seq advanced by the transport's eighths: some steps off, a length of five, and a glide.
  ['sequencing-seq-transport', join(
    {
      modules: [
        m('tx', 'transport'),
        m('seq', 'seq', {
          length: 5, glide: 0.01,
          pitch1: 0, pitch2: 7, pitch3: 12, pitch4: -5, pitch5: 3, pitch6: 24,
          gate2: 0, gate4: 1, gate5: 0,
        }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.2, level3: 0.3 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'eighth'], ['seq', 'clock']), c(['seq', 'pitch'], ['osc', 'pitch']), c(['seq', 'trig'], ['env', 'trig']),
        c(['seq', 'pitch'], ['mix', 'in2']), c(['seq', 'gate'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.03, sustain: 0 }),
  ), 200, [[0, 'transport', 360, 1, 0], [120, 'param', 'seq', 'length', 8], [120, 'param', 'seq', 'glide', 0]]],

  // Seq from a Clock's gate, which holds the voice open for the clock's width; a reset from a slow
  // square, and the length and a pitch turned while it plays.
  ['sequencing-seq-clock-reset', join(
    {
      modules: [
        m('clk', 'clock', { rate: 60, width: 0.6 }),
        m('rst', 'lfo', { rate: 2.3, shape: 3 }),
        m('seq', 'seq', {
          length: 8, glide: 0.004,
          pitch1: -12, pitch2: -7, pitch3: -3, pitch4: 0, pitch5: 2, pitch6: 5, pitch7: 9, pitch8: 14,
          gate3: 0, gate7: 0,
        }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.2, level3: 0.2, level4: 0.2 }),
        m('out', 'out'),
      ],
      cables: [
        c(['clk', 'gate'], ['seq', 'clock']), c(['rst', 'uni'], ['seq', 'reset']),
        c(['seq', 'pitch'], ['osc', 'pitch']), c(['seq', 'gate'], ['env', 'gate']),
        c(['seq', 'pitch'], ['mix', 'in2']), c(['seq', 'gate'], ['mix', 'in3']), c(['seq', 'trig'], ['mix', 'in4']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1'),
  ), 180, [[60, 'param', 'seq', 'length', 3], [100, 'param', 'seq', 'pitch2', 19], [140, 'param', 'seq', 'length', 6]]],

  // All four lane modes from patch data: semitones with rests, unit, a curve through zero (muted
  // for a while, which freezes it) and a muted lane, clocked by the transport's sixteenths.
  ['sequencing-tracker-lanes', join(
    {
      modules: [
        m('tx', 'transport'),
        m('trk', 'tracker', { length: 12, unit2: 1, unit3: 2, mute4: 1 }, {
          data: {
            lane1: [0, 0, 7, 0, 12, 5, 0, -5, 3, 0, 10, 2],
            lane2: [1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0],
            lane3: [8, 4, 0, -4, -8, 0, 16, 12, 0, 2, -2, 0],
            lane4: [1, 1, 1, 1, 1, 1, 1, 1],
          },
        }),
        m('lanes', 'mixer', { level1: 0.3, level2: 0.3, level3: 0.3, level4: 0.3 }),
        m('trigs', 'mixer', { level1: 0.2, level2: 0.2, level3: 0.2, level4: 0.2 }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.4, level3: 0.4 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'sixteenth'], ['trk', 'clock']),
        c(['trk', 'cv1'], ['osc', 'pitch']), c(['trk', 'gate1'], ['env', 'gate']),
        c(['trk', 'cv2'], ['lanes', 'in1']), c(['trk', 'cv3'], ['lanes', 'in2']), c(['trk', 'cv4'], ['lanes', 'in3']),
        c(['trk', 'gate2'], ['lanes', 'in4']),
        c(['trk', 'trig1'], ['trigs', 'in1']), c(['trk', 'trig2'], ['trigs', 'in2']), c(['trk', 'trig3'], ['trigs', 'in3']),
        c(['trk', 'gate4'], ['trigs', 'in4']),
        c(['lanes', 'out'], ['mix', 'in2']), c(['trigs', 'out'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.02, sustain: 0.5, release: 0.01 }),
  ), 220, [
    [0, 'transport', 400, 1, 0], [60, 'param', 'trk', 'mute3', 1], [100, 'param', 'trk', 'mute3', 0],
    [100, 'param', 'trk', 'mute4', 0], [150, 'param', 'trk', 'unit2', 2], [180, 'param', 'trk', 'unit3', 0],
  ]],

  // Banks: two patterns end to end in each lane, chosen by the knob and then by a cable, a pattern
  // pushed while it plays, the length changed, and a reset from a slow square.
  ['sequencing-tracker-patterns', join(
    {
      modules: [
        m('clk', 'clock', { rate: 45, width: 0.5 }),
        m('rst', 'lfo', { rate: 1.7, shape: 3 }),
        m('sel', 'offset', { gain: 0, offset: 0 }),
        m('trk', 'tracker', { length: 6, pattern: 1 }, {
          data: {
            lane1: [0, 3, 0, 7, 0, 10, 12, 0, 15, 0, 19, 24, -12, -12, 0, -7, 0, -5],
            lane2: [1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1],
          },
        }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.3, level3: 0.2, level4: 0.2 }),
        m('out', 'out'),
      ],
      cables: [
        c(['clk', 'gate'], ['trk', 'clock']), c(['rst', 'uni'], ['trk', 'reset']), c(['sel', 'out'], ['trk', 'pattern']),
        c(['trk', 'cv1'], ['osc', 'pitch']), c(['trk', 'trig1'], ['env', 'trig']), c(['trk', 'gate2'], ['env', 'gate']),
        c(['trk', 'cv1'], ['mix', 'in2']), c(['trk', 'gate1'], ['mix', 'in3']), c(['trk', 'trig2'], ['mix', 'in4']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.03, sustain: 0.3 }),
  ), 220, [
    [50, 'param', 'trk', 'pattern', 0], [80, 'param', 'sel', 'offset', 0.125],
    [110, 'data', 'trk', 'lane1', [5, 0, 8, 0, 12, 0, -3, 0, 2, 0, 9, 0, 14, 0, 0, 0, 1, 2]],
    [140, 'param', 'trk', 'length', 9], [170, 'param', 'sel', 'offset', -0.2],
  ]],

  // A song: an Arranger clocked by a fast "bar" choosing a Tracker's pattern and resetting it at
  // every section, with a zero repeat that counts as one.
  ['sequencing-arranger-song', join(
    {
      modules: [
        m('bars', 'clock', { rate: 16, width: 0.5 }),
        m('steps', 'clock', { rate: 72, width: 0.5 }),
        m('song', 'arranger', { length: 4 }, { data: { patterns: [0, 2, 1, 3], repeats: [2, 1, 3, 0] } }),
        m('trk', 'tracker', { length: 4 }, {
          data: { lane1: [0, 12, 0, 7, 3, 0, 5, 0, -5, -5, 0, 2, 10, 0, 17, 19] },
        }),
        m('mix', 'mixer', { level1: 0.6, level2: 1, level3: 0.3 }),
        m('out', 'out'),
      ],
      cables: [
        c(['bars', 'gate'], ['song', 'clock']), c(['steps', 'gate'], ['trk', 'clock']),
        c(['song', 'pattern'], ['trk', 'pattern']), c(['song', 'trig'], ['trk', 'reset']),
        c(['trk', 'cv1'], ['osc', 'pitch']), c(['trk', 'trig1'], ['env', 'trig']),
        c(['song', 'pattern'], ['mix', 'in2']), c(['song', 'trig'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.025, sustain: 0 }),
  ), 260],

  // The song edited while it plays: the patterns replaced, the section count cut and restored, the
  // repeats pushed where the patch had none, and a reset back to the top from a square.
  ['sequencing-arranger-edits', join(
    {
      modules: [
        m('tx', 'transport', { beatsPerBar: 1 }),
        m('rst', 'lfo', { rate: 2.5, shape: 3 }),
        m('song', 'arranger', { length: 3 }, { data: { patterns: [1, 4, 9, -2] } }),
        m('mix', 'mixer', { level1: 0.6, level2: 1, level3: 0.3 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'sixteenth'], ['song', 'clock']), c(['rst', 'uni'], ['song', 'reset']),
        c(['song', 'pattern'], ['osc', 'pitch']), c(['tx', 'eighth'], ['env', 'gate']),
        c(['song', 'pattern'], ['mix', 'in2']), c(['song', 'trig'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { decay: 0.02, sustain: 0.1 }),
  ), 300, [
    [0, 'transport', 400, 1, 0], [60, 'data', 'song', 'patterns', [6, 2, 5.5, 0]],
    [120, 'param', 'song', 'length', 1], [160, 'param', 'song', 'length', 4],
    [180, 'data', 'song', 'repeats', [1, 2, 1, 3]],
  ]],

  // Three voices of MIDI, played by writing each voice's hidden note, gate and velocity as a host
  // does, a chord held and released, and the transpose turned under it.
  ['sequencing-midi-poly', join(
    {
      voices: 3,
      modules: [
        m('keys', 'midi'),
        m('vel', 'vca', { gain: 0 }),
        m('mix', 'mixer', { level1: 0.5, level2: 0.1 }),
        m('out', 'out'),
      ],
      cables: [
        c(['keys', 'pitch'], ['osc', 'pitch']), c(['keys', 'gate'], ['env', 'gate']),
        c(['amp', 'out'], ['vel', 'in']), c(['keys', 'vel'], ['vel', 'cv']),
        c(['vel', 'out'], ['mix', 'in1']), c(['keys', 'pitch'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    {
      modules: [
        m('osc', 'vco', { shape: 0 }),
        m('env', 'adsr', { attack: 0.004, decay: 0.05, sustain: 0.6, release: 0.04 }),
        m('amp', 'vca', { gain: 0 }),
      ],
      cables: [c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv'])],
    },
  ), 180, [
    [2, 'voice', 'keys', 'note', 48, 0], [2, 'voice', 'keys', 'velocity', 1, 0], [2, 'voice', 'keys', 'gate', 1, 0],
    [10, 'voice', 'keys', 'note', 52, 1], [10, 'voice', 'keys', 'velocity', 0.5, 1], [10, 'voice', 'keys', 'gate', 1, 1],
    [18, 'voice', 'keys', 'note', 55, 2], [18, 'voice', 'keys', 'velocity', 0.7, 2], [18, 'voice', 'keys', 'gate', 1, 2],
    [60, 'param', 'keys', 'transpose', 5],
    [90, 'voice', 'keys', 'gate', 0, 1], [100, 'voice', 'keys', 'gate', 0, 0], [110, 'voice', 'keys', 'gate', 0, 2],
    [130, 'voice', 'keys', 'note', 60, 1], [130, 'voice', 'keys', 'gate', 1, 1], [160, 'voice', 'keys', 'gate', 0, 1],
  ]],

  // One voice with a glide, and every continuous outlet — mod, bend, aftertouch, expression,
  // breath, sustain — mixed in as the host writes them.
  ['sequencing-midi-glide-expression', join(
    {
      modules: [
        m('keys', 'midi', { glide: 0.05, transpose: -12 }),
        m('ctl', 'mixer', { level1: 0.2, level2: 0.2, level3: 0.2, level4: 0.2 }),
        m('ctl2', 'mixer', { level1: 0.2, level2: 0.2, level3: 0.2 }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.5, level3: 0.5, level4: 0.2 }),
        m('out', 'out'),
      ],
      cables: [
        c(['keys', 'pitch'], ['osc', 'pitch']), c(['keys', 'gate'], ['env', 'gate']), c(['keys', 'mod'], ['osc', 'fm']),
        c(['keys', 'bend'], ['ctl', 'in1']), c(['keys', 'aftertouch'], ['ctl', 'in2']), c(['keys', 'expression'], ['ctl', 'in3']),
        c(['keys', 'breath'], ['ctl', 'in4']), c(['keys', 'sustain'], ['ctl2', 'in1']), c(['keys', 'vel'], ['ctl2', 'in2']),
        c(['keys', 'pitch'], ['ctl2', 'in3']),
        c(['ctl', 'out'], ['mix', 'in2']), c(['ctl2', 'out'], ['mix', 'in3']), c(['mix', 'out'], ['out', 'in']),
      ],
    },
    voice('', 'mix', 'in1', { sustain: 0.7 }),
  ), 160, [
    [1, 'param', 'keys', 'note', 60], [1, 'param', 'keys', 'gate', 1],
    [30, 'param', 'keys', 'note', 67], [45, 'param', 'keys', 'bend', -0.5], [50, 'param', 'keys', 'mod', 0.1],
    [60, 'param', 'keys', 'aftertouch', 0.7], [70, 'param', 'keys', 'expression', 0.4], [80, 'param', 'keys', 'breath', 0.9],
    [85, 'param', 'keys', 'sustain', 1], [90, 'param', 'keys', 'glide', 0], [95, 'param', 'keys', 'note', 43],
    [120, 'param', 'keys', 'gate', 0], [125, 'param', 'keys', 'sustain', 0], [140, 'param', 'keys', 'velocity', 0.3],
    [140, 'param', 'keys', 'gate', 1],
  ]],

  // Note echo in tempo: eighth-note repeats rising a fifth and fading, from a Seq's notes, with
  // the tempo changed between one note and the next.
  ['sequencing-note-echo-sync', join(
    {
      modules: [
        m('tx', 'transport'),
        m('seq', 'seq', { length: 2, pitch1: 0, pitch2: -5 }),
        m('echo', 'note-echo', { sync: 1, division: 4, repeats: 4, pitch: 7, velocity: 0.8, gate: 0.4 }),
        m('vel', 'vca', { gain: 0 }),
        m('mix', 'mixer', { level1: 0.7, level2: 0.2, level3: 0.2 }),
        m('out', 'out'),
      ],
      cables: [
        c(['tx', 'bar'], ['seq', 'clock']),
        c(['seq', 'pitch'], ['echo', 'pitch']), c(['seq', 'gate'], ['echo', 'gate']),
        c(['echo', 'pitch'], ['osc', 'pitch']), c(['echo', 'gate'], ['env', 'gate']),
        c(['amp', 'out'], ['vel', 'in']), c(['echo', 'velocity'], ['vel', 'cv']),
        c(['vel', 'out'], ['mix', 'in1']), c(['echo', 'gate'], ['mix', 'in2']), c(['echo', 'velocity'], ['mix', 'in3']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    },
    {
      modules: [
        m('osc', 'vco', { shape: 1 }),
        m('env', 'adsr', { attack: 0.002, decay: 0.03, sustain: 0.5, release: 0.01 }),
        m('amp', 'vca', { gain: 0 }),
      ],
      cables: [c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv'])],
    },
  ), 300, [[0, 'transport', 400, 1, 0], [150, 'transport', 250, 1, 0], [200, 'param', 'echo', 'division', 2]]],

  // Note echo in free time, two voices of MIDI, the dry note muted, a step pattern muting some
  // repeats and then replaced, and a note held longer than the echo interval.
  ['sequencing-note-echo-free-steps', join(
    {
      voices: 2,
      modules: [
        m('keys', 'midi'),
        m('echo', 'note-echo', { sync: 0, time: 21, repeats: 6, pitch: -2, velocity: 1.3, gate: 0.3, dry: 0 }, {
          data: { steps: [1, 1, 0, 1, 1, 0, 1] },
        }),
        m('vel', 'vca', { gain: 0 }),
        m('mix', 'mixer', { level1: 0.6, level2: 0.15, level3: 0.15 }),
        m('out', 'out'),
      ],
      cables: [
        c(['keys', 'pitch'], ['echo', 'pitch']), c(['keys', 'gate'], ['echo', 'gate']), c(['keys', 'vel'], ['echo', 'velocity']),
        c(['echo', 'pitch'], ['osc', 'pitch']), c(['echo', 'gate'], ['env', 'gate']),
        c(['amp', 'out'], ['vel', 'in']), c(['echo', 'velocity'], ['vel', 'cv']),
        c(['vel', 'out'], ['mix', 'in1']), c(['echo', 'gate'], ['mix', 'in2']), c(['echo', 'pitch'], ['mix', 'in3']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    },
    {
      modules: [
        m('osc', 'vco', { shape: 2 }),
        m('env', 'adsr', { attack: 0.001, decay: 0.02, sustain: 0.6, release: 0.005 }),
        m('amp', 'vca', { gain: 0 }),
      ],
      cables: [c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv'])],
    },
  ), 260, [
    [2, 'voice', 'keys', 'note', 60, 0], [2, 'voice', 'keys', 'velocity', 0.4, 0], [2, 'voice', 'keys', 'gate', 1, 0],
    [9, 'voice', 'keys', 'note', 64, 1], [9, 'voice', 'keys', 'velocity', 0.6, 1], [9, 'voice', 'keys', 'gate', 1, 1],
    [60, 'voice', 'keys', 'gate', 0, 0], [70, 'voice', 'keys', 'gate', 0, 1],
    [90, 'data', 'echo', 'steps', [0, 1, 1, 0, 1]], [90, 'param', 'echo', 'dry', 1],
    [100, 'voice', 'keys', 'note', 55, 0], [100, 'voice', 'keys', 'gate', 1, 0],
    [180, 'voice', 'keys', 'gate', 0, 0], [180, 'param', 'echo', 'time', 7], [185, 'voice', 'keys', 'gate', 1, 1],
    [230, 'voice', 'keys', 'gate', 0, 1],
  ]],
]
