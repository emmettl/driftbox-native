// Writes the fixtures the Swift tests are held to. The reference is the TypeScript in the
// `driftbox` submodule, run as it stands — see ts-resolve.mjs.
//
//   node conformance/emit/emit.mjs          checked-in fixtures (small, exact, text where possible)
//   node conformance/emit/emit.mjs --full   also whole-song plans, into conformance/generated (ignored)
//   node conformance/emit/emit.mjs --check  write nothing; fail if the checked-in fixtures are stale
//
// Three levels, in rising cost. Documents and events compare exactly. Audio compares within a
// tolerance, and the fixtures that need a browser to render are not produced here yet.
import './ts-resolve.mjs'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..', '..')
const engine = join(root, 'driftbox', 'packages', 'engine', 'src')
const checkedIn = join(root, 'conformance', 'fixtures')
const generated = join(root, 'conformance', 'generated')
const full = process.argv.includes('--full')
const check = process.argv.includes('--check')
// Checking writes a second copy beside the first and compares them, so the comparison can be
// something other than "the bytes are the same" — see AUDIO_TOLERANCE.
const fixtures = check ? mkdtempSync(join(tmpdir(), 'driftbox-fixtures-')) : checkedIn

const { SONGS } = await import(join(engine, 'songs', 'index.ts'))
const { encodeSong, decodeSong, SONG_FORMAT } = await import(join(engine, 'song-io.ts'))
const { planSong, planStep, barLengthForSelection } = await import(join(engine, 'schedule.ts'))
const { bpmAt } = await import(join(engine, 'automation.ts'))
const pattern = await import(join(engine, 'pattern.ts'))
const { songBars } = pattern
const { seededRandom } = await import(join(engine, 'render.ts'))
const { Ladder } = await import(join(engine, 'dsp', 'ladder.ts'))
const { ClockFollower, parseClock, clockBytes, scheduleClockStart, scheduleClockStep } = await import(
  join(engine, 'midi-clock.ts'),
)
const { followClock } = await import(join(root, 'driftbox', 'packages', 'app', 'src', 'clock-follow.ts'))
const { ALL_VOICES, buildVoice } = await import(join(engine, 'kit.ts'))

/** How many bars of each song's plan are checked in. The whole song is `--full`. */
const PLAN_BARS = 4

function write(dir, name, data) {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, name), data)
}
const json = (value) => `${JSON.stringify(value, null, 1)}\n`

rmSync(fixtures, { recursive: true, force: true })

// ── Level 1: documents ───────────────────────────────────────────────────────────────────
// Each catalogue song exactly as the web app would save it. This is also the catalogue the
// native app ships: a song added on the web arrives here by bumping the submodule.
const catalogue = []
for (const preset of SONGS) {
  const text = encodeSong(preset.build())
  const decoded = decodeSong(text)
  if (decoded === null) throw new Error(`${preset.id} does not survive its own codec`)
  // The Swift codec is tested by decoding this text and encoding it again, expecting the same
  // bytes. That is only a fair test while the reference can do it too.
  if (encodeSong(decoded) !== text) throw new Error(`${preset.id} is not a fixed point of its own codec`)
  write(join(fixtures, 'documents'), `${preset.id}.song.json`, text)
  catalogue.push({ id: preset.id, name: preset.name, blurb: preset.blurb, visual: preset.visual })
}
write(fixtures, 'catalogue.json', json({ songFormat: SONG_FORMAT, songs: catalogue }))

// Documents from outside: older formats, hand edits, damage. `decodeSong` repairs what it can and
// refuses the rest, and that behaviour is as much a part of the format as the happy path. Each
// case is an input text and what the reference makes of it, re-encoded — or null for a refusal.
{
  const track = (...on) => Array.from({ length: 16 }, (_, i) => (on.includes(i) ? 1 : 0))
  const base = () => ({
    bpm: 124,
    swing: 0.2,
    patterns: [
      { id: 'a', name: 'A', length: 16, tracks: { '808.bd': track(0, 4, 8, 12) }, bass: {} },
      { id: 'b', name: 'B', length: 8, tracks: { '909.sd': [0, 0, 2, 0, 0, 0, 1, 0] }, bass: {} },
    ],
    chain: [{ pattern: 'a', repeat: 2 }, { pattern: 'b', repeat: 1 }],
    kit: { params: {}, bass: {}, sends: {}, swing: {} },
  })
  const enveloped = (song, v = SONG_FORMAT) => JSON.stringify({ v, song })
  const edit = (change) => {
    const song = base()
    change(song)
    return song
  }

  const inputs = {
    'not json': '{"v":7,"song":',
    'not an object': '[1,2,3]',
    'no patterns': enveloped(edit((s) => (s.patterns = []))),
    'patterns are not objects': enveloped(edit((s) => (s.patterns = [1, 'x', null]))),
    'a future format': enveloped(base(), SONG_FORMAT + 1),
    'a bare song with no envelope': JSON.stringify(base()),
    'a v1 chain of pattern ids': JSON.stringify({ v: 1, song: edit((s) => (s.chain = ['a', 'a', 'b', 'missing'])) }),
    'everything optional missing': enveloped({ patterns: [{}] }),
    'numbers out of range': enveloped(edit((s) => {
      s.bpm = 999
      s.swing = -3
      s.patterns[0].length = 200
      s.chain[0].repeat = 0
      s.kit.params['808.bd'] = { level: 7, tune: -1, decay: 'loud', tone: null }
      s.kit.flam = 4
    })),
    'numbers that are not numbers': enveloped(edit((s) => {
      s.bpm = '120'
      s.swing = null
      s.patterns[0].length = 'long'
      s.kit.flam = 'wide'
    })),
    'halves round the way Math.round does': enveloped(edit((s) => {
      s.bpm = 120.5
      s.patterns[0].length = 12.5
      s.chain[0].repeat = 2.5
      s.patterns[1].trackLengths = { '909.sd': 4.5, '909.bd': 8, '': 3, '909.ch': 'x' }
    })),
    'bad steps cost the step, not the track': enveloped(edit((s) => {
      s.patterns[0].tracks['808.sd'] = [1, 2, 3, -1, 'x', null, true, 1.5]
      s.patterns[0].tracks['808.ch'] = 'not an array'
      s.patterns[0].pcf = [0, 1, 2, 9]
      s.patterns[0].flams = { '909.sd': [true, 1, 'yes', false], '909.bd': {} }
    })),
    'bass lines': enveloped(edit((s) => {
      s.patterns[0].bass = {
        '303.a': [
          { note: 0, accent: true, slide: false },
          { note: 30, accent: 1, slide: 'yes' },
          { note: -4, accent: false, slide: true, gate: false },
          { note: 7.5, accent: false, slide: false, gate: 'open' },
          { note: null, accent: false, slide: true },
          'rest',
          null,
        ],
        '303.b': 12,
      }
      s.kit.bass = { '303.a': { cutoff: 0.9, resonance: 2, extra: 1 } }
    })),
    'clips keep only slots and patterns that exist': enveloped(edit((s) => {
      s.chain[0].clips = { tr808: 'b', tr909: 'missing', '303.a': 7, 'tr707': 'a' }
      s.chain[1].clips = { tr909: 'ghost' }
      s.chain.push({ pattern: 'missing', repeat: 4 }, { repeat: 2 }, 'a')
    })),
    'automation is de-duplicated, sorted and clamped': enveloped(edit((s) => {
      s.automation = [
        { target: 'song/bpm', interpolation: 'hold', points: [{ bar: 2, index: 0, value: 900 }, { bar: 0, index: 4, value: 5 }, { bar: 0, index: 4, value: 140 }] },
        { target: 'voice/808.bd/decay', points: [{ bar: 1.5, index: 70, value: 2 }, { bar: -1, index: -1, value: -2 }] },
        { target: 'voice/808.bd/decay', points: [{ bar: 0, index: 0, value: 0.1 }] },
        { target: 'host/unknown', interpolation: 'cubic', points: [{ bar: 0, index: 0, value: 5e9 }] },
        { target: '   ', points: [{ bar: 0, index: 0, value: 1 }] },
        { target: 'fx/drive', points: [] },
        { target: 'fx/drive', points: [{ bar: 0, index: 0, value: 'x' }, 4] },
        'nonsense',
      ]
    })),
    'visual is trimmed and kit send and swing are repaired': enveloped(edit((s) => {
      s.visual = '   trench   '
      s.kit.sends = { '808.bd': { delay: 0.3 }, '909.sd': 'wet' }
      s.kit.swing = { '808.ch': 1.4, '909.ch': 'late' }
      s.fx = { drive: 0.4, delayTime: 3, unknown: 1 }
    })),
    'an empty visual is dropped': enveloped(edit((s) => (s.visual = '   '))),
    'names fall back to ids and ids to positions': enveloped(edit((s) => {
      s.patterns = [{ length: 4, tracks: {} }, { id: '', name: '', length: 4, tracks: {} }, { id: 'c', name: 7 }]
      s.chain = [{ pattern: 'pattern-0', repeat: 1 }, { pattern: 'pattern-1', repeat: 1 }]
    })),
    'escapes and unicode survive': enveloped(edit((s) => {
      s.patterns[0].name = 'Quote " slash \\ tab \t nl \n é 日本 🥁 \u0001'
    })),
  }

  write(fixtures, 'documents-repair.json', json(Object.entries(inputs).map(([name, input]) => {
    const song = decodeSong(input)
    return { name, input, output: song === null ? null : encodeSong(song) }
  })))
}

// ── Level 2: events ──────────────────────────────────────────────────────────────────────
// What the sequencer decides, with no audio involved: every hit, its time, and the knobs and
// sends resolved at that position. Planned from the decoded document, because that is what a
// native reader starts from.
for (const preset of SONGS) {
  const song = decodeSong(encodeSong(preset.build()))
  const bars = songBars(song)
  // One step per line: compact enough to check in, and a change shows up as the steps it moved.
  const steps = planSong(song, PLAN_BARS).map((step) => JSON.stringify(step)).join(',\n')
  write(join(fixtures, 'events'), `${preset.id}.plan.json`, `{"bars":${PLAN_BARS},"songBars":${bars},"steps":[\n${steps}\n]}\n`)
  if (full) write(join(generated, 'events'), `${preset.id}.plan.json`, JSON.stringify({ bars, steps: planSong(song, bars) }))
}

// The catalogue does not use everything the sequencer can do — no song in it has machine clips,
// short drum lanes, flams or filter strikes — so a plan that matched all 25 would say nothing about
// those. These songs exist to be awkward: they are written here, passed through the reference's
// own decoder so they are valid, and planned whole.
{
  const steps = (length, ...on) => Array.from({ length }, (_, i) => (on.includes(i) ? (i % 8 === 0 ? 2 : 1) : 0))
  const line = (length, notes) => Array.from({ length }, (_, i) => notes[i] ?? { note: null, accent: false, slide: false })
  const n = (note, accent = false, slide = false, gate) => ({ note, accent, slide, ...(gate === undefined ? {} : { gate }) })

  const awkward = {
    bpm: 132,
    swing: 0.3,
    patterns: [
      {
        id: 'groove', name: 'Groove', length: 16,
        tracks: {
          '808.bd': steps(16, 0, 4, 8, 12), '808.ch': steps(16, 1, 3, 5, 7, 9, 11, 13, 15),
          '909.sd': steps(16, 4, 12), '909.ch': steps(16, 2, 3, 6, 7, 10, 11, 14, 15), 'x.unknown': steps(16, 0, 7),
        },
        trackLengths: { '808.ch': 6, '909.sd': 5 },
        flams: { '909.sd': Array.from({ length: 16 }, (_, i) => i === 4), '808.bd': Array.from({ length: 16 }, () => true) },
        bass: {
          '303.a': line(16, { 0: n(0, true), 1: n(12, false, true), 2: n(7), 3: n(3, false, true, false), 4: n(5), 7: n(24, true, true), 8: n(0), 15: n(10, false, true) }),
        },
        pcf: steps(16, 0, 6, 8, 14),
      },
      { id: 'short909', name: 'Short 909', length: 8, tracks: { '909.bd': steps(8, 0, 3, 6), '909.sd': steps(8, 2, 5) }, flams: { '909.sd': [false, false, true, false, false, true, false, false] }, bass: {} },
      { id: 'long303', name: 'Long 303', length: 24, tracks: {}, bass: { '303.a': line(24, { 0: n(0), 5: n(7, true, true), 6: n(9), 23: n(2, false, true) }), '303.b': line(24, { 3: n(12), 11: n(15, true) }) } },
      { id: 'odd', name: 'Odd', length: 7, tracks: { '808.bd': steps(7, 0, 3, 5), '808.cp': steps(7, 6) }, bass: { '303.b': line(7, { 0: n(4, false, true), 1: n(4), 6: n(16, true, true) }) }, pcf: steps(7, 0, 3) },
    ],
    chain: [
      { pattern: 'groove', repeat: 2 },
      { pattern: 'groove', repeat: 1, clips: { tr909: 'short909', '303.a': 'long303', '303.b': 'long303' } },
      { pattern: 'odd', repeat: 3 },
      { pattern: 'odd', repeat: 1, clips: { tr808: 'groove', tr909: 'short909' } },
    ],
    kit: {
      params: { '808.bd': { level: 0.9, tune: 0.4, decay: 0.6, tone: 0.5, colour: 0.2, pan: 0.5 } },
      bass: { '303.a': { tune: 0.37, wave: 0.8, cutoff: 0.41, resonance: 0.93, envMod: 0.77, decay: 0.18, accent: 0.85, level: 0.66 } },
      sends: { '909.sd': { delay: 0.3, reverb: 0.5 }, '303.a': { delay: 0.2, reverb: 0.1 } },
      swing: { '808.ch': 0.9, '909.ch': 0.1, '303.a': 0.5 },
      flam: 0.85,
    },
    fx: { drive: 0.2, pcfAmount: 0.7 },
    automation: [
      { target: 'song/bpm', interpolation: 'linear', points: [{ bar: 0, index: 8, value: 132 }, { bar: 2, index: 12, value: 171.5 }, { bar: 5, index: 3, value: 96 }] },
      { target: 'song/swing', interpolation: 'hold', points: [{ bar: 1, index: 0, value: 0.7 }, { bar: 4, index: 2, value: 0 }] },
      { target: 'swing/808.bd', interpolation: 'linear', points: [{ bar: 0, index: 0, value: 0.5 }, { bar: 3, index: 0, value: 1 }] },
      { target: 'voice/808.bd/decay', interpolation: 'linear', points: [{ bar: 1, index: 4, value: 0.1 }, { bar: 3, index: 6, value: 1 }] },
      { target: 'bass/303.a/cutoff', interpolation: 'linear', points: [{ bar: 0, index: 0, value: 0 }, { bar: 6, index: 6, value: 1 }] },
      { target: 'send/909.sd/reverb', interpolation: 'hold', points: [{ bar: 2, index: 0, value: 1 }] },
      { target: 'fx/delayFeedback', interpolation: 'linear', points: [{ bar: 0, index: 0, value: 0.1 }, { bar: 0, index: 0, value: 0.2 }, { bar: 7, index: 0, value: 0.9 }] },
    ],
  }

  const cases = [
    { name: 'awkward', song: awkward, bars: 9 },
    { name: 'awkward with clips launched', song: awkward, bars: 5, selection: { tr909: 'short909', '303.a': 'long303', tr808: 'missing' } },
    { name: 'no chain plays the first pattern', song: { ...awkward, chain: [], automation: [] }, bars: 2 },
  ]

  const planned = cases.map(({ name, song: raw, bars, selection }) => {
    const text = encodeSong(decodeSong(JSON.stringify(raw)))
    const song = decodeSong(text)
    let planned
    if (!selection) {
      planned = planSong(song, bars)
    } else {
      // `planSong` has no way to say a clip was launched, so this walks the same ground by hand.
      planned = []
      let time = 0
      for (let bar = 0; bar < bars; bar++) {
        for (let index = 0; index < barLengthForSelection(song, bar, selection); index++) {
          const stepSeconds = 60 / bpmAt(song, bar, index) / 4
          planned.push(planStep(song, { absolute: planned.length, index, bar, time, stepSeconds }, selection))
          time += stepSeconds
        }
      }
    }
    const head = JSON.stringify({ name, song: text, bars, ...(selection ? { selection } : {}) })
    return `${head.slice(0, -1)},"steps":[\n${planned.map((step) => JSON.stringify(step)).join(',\n')}\n]}`
  })
  write(join(fixtures, 'events'), 'synthetic.json', `[\n${planned.join(',\n')}\n]\n`)
}

// The edits: every pure transform in pattern.ts, applied to a catalogue song, with the result
// the reference gives. The Swift edits are held to these exactly. Where an edit wants chance it
// is given the reference's own PRNG at a fixed seed, so the answer is one answer.
{
  const song = decodeSong(encodeSong(SONGS.find((preset) => preset.id === 'garage').build()))
  const first = song.patterns[0]
  const drum = Object.keys(first.tracks)[0]
  const drumWithFlams = { ...first, flams: { [drum]: first.tracks[drum].map((_, i) => i % 5 === 0) }, trackLengths: { [drum]: 10 } }
  const bassId = Object.keys(first.bass ?? {})[0] ?? '303.a'
  const withSong = (patterns) => ({ ...song, patterns })
  const edits = [
    ['addPattern', () => pattern.addPattern(song).song],
    ['addPattern twice', () => pattern.addPattern(pattern.addPattern(song).song).song],
    ['duplicatePattern', () => pattern.duplicatePattern(song, first.id).song],
    ['duplicatePattern twice', () => { const once = pattern.duplicatePattern(song, first.id).song; return pattern.duplicatePattern(once, first.id).song }],
    ['renamePattern', () => pattern.renamePattern(song, first.id, '  Renamed  ')],
    ['renamePattern to blank is refused', () => pattern.renamePattern(song, first.id, '   ')],
    ['removePattern', () => pattern.removePattern(song, song.patterns[1].id)],
    ['chainAppend', () => ({ ...song, chain: pattern.chainAppend(song, first.id) })],
    ['chainRemove', () => ({ ...song, chain: pattern.chainRemove(song, 1) })],
    ['chainSetRepeat', () => ({ ...song, chain: pattern.chainSetRepeat(song, 0, 99) })],
    ['chainSetPattern', () => ({ ...song, chain: pattern.chainSetPattern(song, 2, first.id) })],
    ['chainMove', () => ({ ...song, chain: pattern.chainMove(song, 0, 2) })],
    ['chainMove out of range', () => ({ ...song, chain: pattern.chainMove(song, 0, -1) })],
    ['rotateTrack', () => withSong([pattern.rotateTrack(drumWithFlams, drum, 3)])],
    ['rotateTrack backwards', () => withSong([pattern.rotateTrack(drumWithFlams, drum, -7)])],
    ['rotateBassLine', () => withSong([pattern.rotateBassLine(first, bassId, 5)])],
    ['transposeBassLine', () => withSong([pattern.transposeBassLine(first, bassId, 7)])],
    ['transposeBassLine down past the floor', () => withSong([pattern.transposeBassLine(first, bassId, -30)])],
    ['randomizeTrack', () => withSong([pattern.randomizeTrack(drumWithFlams, drum, seededRandom(0x1234))])],
    ['randomizeBassLine', () => withSong([pattern.randomizeBassLine(first, bassId, seededRandom(0x1234))])],
    ['alterTrack', () => withSong([pattern.alterTrack(drumWithFlams, drum, seededRandom(0x4321))])],
    ['alterBassLine', () => withSong([pattern.alterBassLine(first, bassId, seededRandom(0x4321))])],
    ['clearTrack', () => withSong([pattern.clearTrack(drumWithFlams, drum)])],
    ['clearBassLine', () => withSong([pattern.clearBassLine(first, bassId)])],
    ['setTrackLength', () => withSong([pattern.setTrackLength(first, drum, 6)])],
    ['setTrackLength to full clears it', () => withSong([pattern.setTrackLength(drumWithFlams, drum, 16)])],
    ['toggleFlam on a rest', () => withSong([pattern.toggleFlam(first, drum, 1)])],
    ['toggleFlam off again', () => withSong([pattern.toggleFlam(pattern.toggleFlam(first, drum, 1), drum, 1)])],
  ]
  write(fixtures, 'edits.json', json({
    song: encodeSong(song),
    drum, bass: bassId, flams: drumWithFlams.flams[drum], trackLength: 10,
    edits: edits.map(([name, apply]) => ({ name, output: encodeSong(decodeSong(encodeSong(apply()))) })),
  }))
}

// A MIDI clock, followed. A synthetic stream — start, ticks at a tempo with jitter and a tempo
// change, a dropped tick, a stop, a position and a continue — through the reference's estimator
// and the app's follow rules, with what each message made of them. Times in milliseconds.
{
  const random = seededRandom(0xc10c)
  const events = []
  let time = 1000
  const push = (bytes) => events.push({ time: Math.round(time * 1000) / 1000, bytes })
  push([0xfa])
  let bpm = 120
  for (let tick = 0; tick < 400; tick++) {
    if (tick === 200) bpm = 140
    time += 60000 / (bpm * 24) + (random() - 0.5) * 1.5
    if (tick === 150) continue  // lost on the wire
    push([0xf8])
  }
  push([0xfc])
  time += 300
  push([0xf2, 32, 0])
  push([0xfb])
  for (let tick = 0; tick < 60; tick++) {
    time += 60000 / (bpm * 24) + (random() - 0.5) * 1.5
    push([0xf8])
  }
  time += 900
  push([0xf8])

  const follower = new ClockFollower()
  let local = { bpm: 120, ticks: 0, time: 1000 }
  const trace = events.map(({ time, bytes }) => {
    const message = parseClock(bytes)
    const command = followClock(message, time, follower, local)
    if (command.bpm !== undefined) local = { ...local, bpm: command.bpm }
    // The local transport runs at its tempo between messages: ticks advance in the ratio.
    local.ticks = (local.ticks ?? 0) + (time - local.time) * local.bpm * 24 / 60000
    local.time = time
    const state = follower.state
    return { time, bytes, command, state: { bpm: state.bpm, running: state.running, ticks: state.ticks }, step: follower.step }
  })
  write(fixtures, 'midi-clock.json', `[\n${trace.map((entry) => JSON.stringify(entry)).join(',\n')}\n]\n`)

  // And the other direction: what Driftbox SENDS when it is the clock. Starting anywhere but
  // the top has to say where before it says go, and a step is six pulses — the awkward cases
  // are a fractional step, a negative one, and a step length that is not a number.
  const out = []
  for (const step of [0, 1, 4, 15, 16, 63, 0.4, 7.9, -1, 16383, 16384, 20000]) {
    out.push({ call: 'start', step, result: scheduleClockStart(step, 12.5) })
  }
  for (const [time, seconds] of [[0, 0.125], [1.5, 0.11904761904761904], [3, 0.5], [0, 0], [0, -1]]) {
    out.push({ call: 'step', time, seconds, result: scheduleClockStep(time, seconds) })
  }
  for (const message of [
    { message: 'tick' }, { message: 'start' }, { message: 'continue' }, { message: 'stop' },
    { message: 'position', step: 0 }, { message: 'position', step: 1 },
    { message: 'position', step: 129 }, { message: 'position', step: 16383 },
    { message: 'position', step: 16384 }, { message: 'position', step: -3 },
    { message: 'position', step: 7.9 },
  ]) {
    out.push({ call: 'bytes', message, result: clockBytes(message) })
  }
  write(fixtures, 'midi-clock-out.json', `[\n${out.map((entry) => JSON.stringify(entry)).join(',\n')}\n]\n`)
}

// The noise generator, as the integers behind the floats so no decimal printing is involved.
const SEEDS = [1, 0x808, 0x909, 0xdeadbeef, 0]
write(join(fixtures, 'prng'), 'xorshift32.json', json(SEEDS.map((seed) => {
  const next = seededRandom(seed)
  return { seed, first: Array.from({ length: 32 }, () => next() * 0x1_0000_0000) }
})))

// Every drum voice is a function from its panel to a description of a sound. The description is
// data, so it compares exactly — and with it pinned down, any difference in the *sound* belongs to
// the renderer and not to the voice. Panels: the defaults, every knob at each end, and a run of
// arbitrary ones from the reference's own PRNG.
{
  const KNOBS = ['level', 'tune', 'decay', 'tone', 'colour', 'pan']
  const all = (value) => Object.fromEntries(KNOBS.map((knob) => [knob, value]))
  const random = seededRandom(0x5eed)
  const panels = [
    all(0.5), { ...all(0.5), level: 0.8 }, all(0), all(1),
    ...Array.from({ length: 5 }, () => Object.fromEntries(KNOBS.map((knob) => [knob, random()]))),
  ]
  const lines = []
  for (const voice of ALL_VOICES) {
    for (const params of panels) {
      for (const accent of [1, 0.55]) {
        lines.push(JSON.stringify({ voice: voice.id, params, accent, spec: buildVoice(voice, params, accent) }))
      }
    }
  }
  write(join(fixtures, 'voices'), 'specs.json', `[\n${lines.join(',\n')}\n]\n`)
  write(join(fixtures, 'voices'), 'kit.json', json(ALL_VOICES.map(({ id, name, machine, choke, trim, pitched }) => ({ id, name, machine, choke, trim, pitched }))))
}

// ── Level 3: audio ───────────────────────────────────────────────────────────────────────
// Only what is plain arithmetic, so far. Four little-endian float64 columns per frame — input,
// cutoff, resonance, output — at double precision on purpose: it shows a difference between two
// maths libraries that a float32 comparison would round away.
{
  const sampleRate = 48000
  const frames = 4096
  const ladder = new Ladder(sampleRate)
  const out = new Float64Array(frames * 4)
  let phase = 0
  for (let i = 0; i < frames; i++) {
    phase = (phase + 55 / sampleRate) % 1
    const input = 2 * phase - 1
    const cutoff = 200 + 3000 * Math.exp(-((i % 2048) / 400))
    const resonance = i < frames / 2 ? 0.95 : 0.4
    out.set([input, cutoff, resonance, ladder.process(input, cutoff, resonance)], i * 4)
  }
  write(join(fixtures, 'dsp'), 'ladder.f64', Buffer.from(out.buffer))
  write(join(fixtures, 'dsp'), 'ladder.json', json({ sampleRate, frames, columns: ['input', 'cutoff', 'resonance', 'output'] }))
}

// Which reference produced all this.
const git = (...args) => execFileSync('git', ['-C', join(root, 'driftbox'), ...args], { encoding: 'utf8' }).trim()
write(fixtures, 'REFERENCE.json', json({ driftbox: git('rev-parse', 'HEAD'), describe: git('log', '-1', '--format=%cs %s') }))

// ── --check ──────────────────────────────────────────────────────────────────────────────
// Text fixtures must match to the byte: documents, events and PRNG bits came out identical on an
// arm64 Mac and an x64 Linux runner, so a difference there is a real one.
//
// Audio fixtures cannot be held to that. The same ladder render from the same TypeScript differs
// in its last bits between those two machines — V8's `exp` and `tanh` are the same source compiled
// for different hardware — so the reference is not bit-reproducible with itself at double
// precision, and a byte comparison would fail on every machine but the one that last ran the
// emitter. They are compared within the tolerance the Swift tests use.
// The rack: patches rendered by the reference's headless `RackRenderer`, one block at a time, with
// the knob moves each case makes at the blocks it makes them. Beside each render, the plan the
// reference compiles the patch to, so the compiler is held to the reference as well as the sound.
// Written as float32, which is what every rack buffer is.
{
  const rack = join(root, 'driftbox', 'packages', 'rack', 'src')
  const { RackRenderer } = await import(join(rack, 'headless.ts'))
  const { compile } = await import(join(rack, 'compile.ts'))
  const { MODULES } = await import(join(rack, 'modules', 'index.ts'))
  const m = (id, type, params, extra = {}) => ({ id, type, ...(params ? { params } : {}), ...extra })
  const c = (from, to) => ({ from, to })
  const cases = [
    ['vco-saw', { modules: [m('osc', 'vco'), m('out', 'out')], cables: [c(['osc', 'out'], ['out', 'in'])] }, 16],
    ['vco-pulse', { modules: [m('osc', 'vco', { shape: 1, width: 0.3, tune: -7 }), m('out', 'out')], cables: [c(['osc', 'out'], ['out', 'in'])] }, 16],
    ['vco-tri', { modules: [m('osc', 'vco', { shape: 2, tune: 12 }), m('out', 'out')], cables: [c(['osc', 'out'], ['out', 'in'])] }, 16],
    ['noise', {
      modules: [m('hiss', 'noise'), m('mix', 'mixer', { level2: 0.5 }), m('out', 'out')],
      cables: [c(['hiss', 'white'], ['mix', 'in1']), c(['hiss', 'pink'], ['mix', 'in2']), c(['mix', 'out'], ['out', 'in'])],
    }, 16],
    ['lfo-shapes', {
      modules: [0, 1, 2, 3].map((shape) => m(`lfo${shape}`, 'lfo', { rate: 37, shape })).concat([m('mix', 'mixer', { level1: 0.25, level2: 0.25, level3: 0.25, level4: 0.25 }), m('out', 'out')]),
      cables: [0, 1, 2, 3].map((shape) => c([`lfo${shape}`, shape % 2 ? 'uni' : 'bi'], ['mix', `in${shape + 1}`])).concat([c(['mix', 'out'], ['out', 'in'])]),
    }, 24],
    ['lfo-random', {
      modules: [m('wander', 'lfo', { rate: 29, shape: 4 }), m('osc', 'vco'), m('out', 'out')],
      cables: [c(['wander', 'bi'], ['osc', 'pitch']), c(['osc', 'out'], ['out', 'in'])],
    }, 24],
    ['adsr-vca', {
      modules: [m('clock', 'lfo', { rate: 8, shape: 3 }), m('env', 'adsr', { attack: 0.005, decay: 0.05, sustain: 0.5, release: 0.02 }), m('osc', 'vco'), m('amp', 'vca', { gain: 0 }), m('out', 'out')],
      cables: [c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']), c(['amp', 'out'], ['out', 'in'])],
    }, 64],
    ['ladder', {
      modules: [m('osc', 'vco', { tune: -12 }), m('sweep', 'lfo', { rate: 3 }), m('filter', 'ladder', { cutoff: 1200, resonance: 0.85 }), m('out', 'out')],
      cables: [c(['osc', 'out'], ['filter', 'in']), c(['sweep', 'bi'], ['filter', 'cutoff']), c(['filter', 'out'], ['out', 'in'])],
    }, 32],
    ['svf', {
      modules: [m('hiss', 'noise'), m('wobble', 'lfo', { rate: 5 }), m('filter', 'svf', { cutoff: 2000, resonance: 0.7 }), m('mix', 'mixer', { level2: 0.3, level4: 0.2 }), m('out', 'out')],
      cables: [
        c(['hiss', 'white'], ['filter', 'in']), c(['wobble', 'uni'], ['filter', 'res']),
        c(['filter', 'lp'], ['mix', 'in1']), c(['filter', 'hp'], ['mix', 'in2']), c(['filter', 'bp'], ['mix', 'in3']), c(['filter', 'notch'], ['mix', 'in4']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    }, 32],
    ['sample-hold', {
      modules: [m('hiss', 'noise'), m('clock', 'lfo', { rate: 20, shape: 3 }), m('hold', 'sample-hold'), m('osc', 'vco'), m('out', 'out')],
      cables: [c(['hiss', 'white'], ['hold', 'in']), c(['clock', 'uni'], ['hold', 'trig']), c(['hold', 'out'], ['osc', 'pitch']), c(['osc', 'out'], ['out', 'in'])],
    }, 32],
    ['delay', {
      modules: [
        m('clock', 'lfo', { rate: 6, shape: 3 }), m('env', 'adsr', { attack: 0.001, decay: 0.03, sustain: 0, release: 0.01 }),
        m('osc', 'vco', { shape: 1 }), m('amp', 'vca', { gain: 0 }), m('drift', 'lfo', { rate: 0.7 }),
        m('echo', 'delay', { time: 0.013, feedback: 0.6 }), m('mix', 'mixer', { level1: 0.7 }), m('out', 'out'),
      ],
      cables: [
        c(['clock', 'uni'], ['env', 'gate']), c(['osc', 'out'], ['amp', 'in']), c(['env', 'out'], ['amp', 'cv']),
        c(['amp', 'out'], ['echo', 'in']), c(['drift', 'bi'], ['echo', 'time']), c(['echo', 'out'], ['mix', 'in1']), c(['amp', 'out'], ['mix', 'in2']),
        c(['mix', 'out'], ['out', 'in']),
      ],
    }, 64],
    ['offset', {
      modules: [m('sweep', 'lfo', { rate: 11, shape: 1 }), m('shift', 'offset', { gain: -0.5, offset: 0.25 }), m('osc', 'vco'), m('out', 'out')],
      cables: [c(['sweep', 'bi'], ['shift', 'in']), c(['shift', 'out'], ['osc', 'pitch']), c(['osc', 'out'], ['out', 'in'])],
    }, 24],
    ['feedback', {
      modules: [m('osc', 'vco'), m('filter', 'svf', { cutoff: 700, resonance: 0.5 }), m('mix', 'mixer', { level1: 0.8 }), m('out', 'out')],
      cables: [c(['osc', 'out'], ['filter', 'in']), c(['filter', 'bp'], ['mix', 'in1']), c(['mix', 'out'], ['osc', 'fm']), c(['mix', 'out'], ['out', 'in'])],
    }, 32],
    ['ramps', {
      modules: [m('osc', 'vco', { tune: -5 }), m('filter', 'ladder', { cutoff: 500, resonance: 0.3 }), m('out', 'out')],
      cables: [c(['osc', 'out'], ['filter', 'in']), c(['filter', 'out'], ['out', 'in'])],
    }, 20, [
      [4, 'param', 'filter', 'cutoff', 3000], [8, 'param', 'osc', 'shape', 1],
      [10, 'schedule', 'filter', 'cutoff', 400, 10 * 128 + 37], [12, 'param', 'out', 'level', 0.3],
      [12, 'schedule', 'osc', 'tune', 2, 13 * 128 + 5], [12, 'schedule', 'osc', 'tune', 7, 13 * 128 + 90],
    ]],
    ['master', {
      modules: [
        m('lead', 'vco', { tune: 3 }), m('near', 'out', { level: 1, pan: -0.6 }),
        m('hiss', 'noise'), m('far', 'out', { pan: 0.8 }),
        m('loud', 'vco', { shape: 1, tune: -9 }), m('stack', 'mixer', { level1: 2, level2: 2, level3: 2, level4: 2 }), m('wall', 'out', { level: 1 }),
      ],
      cables: [
        c(['lead', 'out'], ['near', 'in']), c(['hiss', 'pink'], ['far', 'in']),
        c(['loud', 'out'], ['stack', 'in1']), c(['loud', 'out'], ['stack', 'in2']), c(['loud', 'out'], ['stack', 'in3']), c(['loud', 'out'], ['stack', 'in4']),
        c(['stack', 'out'], ['wall', 'in']),
      ],
    }, 32, [[8, 'param', 'near', 'mute', 1], [16, 'param', 'wall', 'solo', 1], [24, 'param', 'wall', 'solo', 0]]],
    ['placeholder-bypass', {
      modules: [m('osc', 'vco'), m('ghost', 'futurething', { depth: 3 }), m('filter', 'ladder', { cutoff: 300 }, { bypassed: true }), m('out', 'out')],
      cables: [c(['osc', 'out'], ['ghost', 'in']), c(['ghost', 'out'], ['out', 'in']), c(['osc', 'out'], ['filter', 'in']), c(['filter', 'out'], ['out', 'in'])],
    }, 16],
    ['poly', {
      voices: 3,
      modules: [m('wobble', 'lfo', { rate: 4 }), m('osc', 'vco', { tune: -12 }), m('amp', 'vca', { gain: 0.3 }), m('out', 'out')],
      cables: [c(['wobble', 'bi'], ['osc', 'fm']), c(['osc', 'out'], ['amp', 'in']), c(['amp', 'out'], ['out', 'in'])],
    }, 24, [[0, 'voice', 'osc', 'tune', 0, 0], [0, 'voice', 'osc', 'tune', 4, 1], [0, 'voice', 'osc', 'tune', 7, 2]]],
    ['stereo-thru', {
      modules: [m('osc', 'vco'), m('first', 'out', { level: 0.5, pan: 0.5 }), m('second', 'out', { level: 0.8 })],
      cables: [c(['osc', 'out'], ['first', 'in']), c(['first', 'out'], ['second', 'in'])],
    }, 16],
  ]
  // Host input buses, when a case has them: bus b, channel c is a sine at 110(b+1) + 3c Hz at half
  // scale, the same on both sides because it is float32 by the time anything reads it.
  const hostBlock = (buses, block) => Array.from({ length: buses }, (_, bus) => [0, 1].map((channel) => {
    const out = new Float32Array(128)
    const frequency = 110 * (bus + 1) + 3 * channel
    for (let i = 0; i < 128; i++) out[i] = 0.5 * Math.sin((2 * Math.PI * frequency * (block * 128 + i)) / 48000)
    return out
  }))
  // Each family of modules keeps its cases in a file of its own, `rack-cases-<family>.mjs`, whose
  // default export is a list of cases in the shape below, so the families can be ported apart.
  for (const file of readdirSync(here).filter((name) => /^rack-cases-.+\.mjs$/.test(name)).sort()) {
    const { default: more } = await import(join(here, file))
    cases.push(...more)
  }
  const summary = []
  // A case is [name, patch, blocks, events, host buses]. An event is [block, kind, ...]:
  //   param    module param value            a knob, every voice
  //   voice    module param value voice      a knob, one voice
  //   schedule module param value frame      a knob at an exact frame
  //   transport tempo running shuffle        the transport (running is 1 or 0)
  //   data     module slot values            bulk data pushed to a module
  for (const [name, patch, blocks, events = [], hostBuses = 0] of cases) {
    const renderer = new RackRenderer(MODULES, { sampleRate: 48000, frames: 128 })
    renderer.patch = patch
    const left = new Float32Array(blocks * 128)
    const right = new Float32Array(blocks * 128)
    for (let block = 0; block < blocks; block++) {
      for (const [at, kind, a, b, c, d] of events) {
        if (at !== block) continue
        if (kind === 'param') renderer.setParam(a, b, c)
        else if (kind === 'voice') renderer.setParam(a, b, c, d)
        else if (kind === 'schedule') renderer.scheduleParam(a, b, c, d)
        else if (kind === 'transport') renderer.setTransport(a, b === 1, c ?? 0)
        else if (kind === 'data') renderer.setData(a, b, Float32Array.from(c))
        else throw new Error(`unknown rack event ${kind}`)
      }
      const l = new Float32Array(128)
      const r = new Float32Array(128)
      renderer.process([l, r], hostBuses > 0 ? hostBlock(hostBuses, block) : [])
      left.set(l, block * 128)
      right.set(r, block * 128)
    }
    const both = new Float32Array(blocks * 256)
    both.set(left, 0)
    both.set(right, blocks * 128)
    write(join(fixtures, 'rack'), `${name}.f32`, Buffer.from(both.buffer))
    const plan = compile(patch, MODULES)
    summary.push({
      name, patch, blocks, events, hostBuses,
      plan: {
        buffers: plan.buffers, voices: plan.voices, voiceWidths: plan.voiceWidths,
        nodes: plan.nodes.map(({ id, type, inlets, inletConnected, inletTrims, outlets, outletConnected, params, poly, voices, voiceLanes }) =>
          ({ id, type, inlets, inletConnected, inletTrims: inletTrims.map((slot) => slot ?? null), outlets, outletConnected, params, poly, voices, voiceLanes })),
        outputs: plan.outputs,
        params: plan.params,
        notes: plan.notes.map(({ kind, module }) => ({ kind, module: module ?? null })),
      },
    })
  }
  write(join(fixtures, 'rack'), 'cases.json', json(summary))
  // Every module's definition, which is the file format: ids, ports, param ranges and defaults.
  const port = ({ id, stereo }) => ({ id, stereo: stereo === true })
  write(join(fixtures, 'rack'), 'modules.json', json(Object.values(MODULES).map((def) => ({
    type: def.type, version: def.version, name: def.name,
    inlets: def.inlets.map(port), outlets: def.outlets.map(port),
    params: def.params.map(({ id, min, max, stepped, hidden, ...rest }) =>
      ({ id, min, max, default: rest.default, stepped: stepped === true, hidden: hidden === true })),
    poly: def.poly !== false, terminal: def.terminal === true, voiceExpansion: def.voiceExpansion ?? null,
    voiceCollector: def.voiceCollector === true,
  }))))
}

const AUDIO_TOLERANCE = 1e-12

function filesUnder(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? filesUnder(join(dir, entry.name), base) : [relative(base, join(dir, entry.name))],
  )
}

if (check) {
  const fresh = filesUnder(fixtures).sort()
  const stale = []
  for (const name of new Set([...fresh, ...filesUnder(checkedIn)])) {
    let a, b
    try {
      a = readFileSync(join(fixtures, name))
      b = readFileSync(join(checkedIn, name))
    } catch {
      stale.push(`${name}: only on one side`)
      continue
    }
    if (name.endsWith('.f32')) {
      // Float32 renders: the same arithmetic on another Node could differ in the last bit of a
      // transcendental, so this is a tolerance rather than a byte comparison.
      const floats = (buffer) => new Float32Array(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength))
      const x = floats(a)
      const y = floats(b)
      let worst = x.length === y.length ? 0 : Infinity
      for (let i = 0; i < x.length && worst !== Infinity; i++) worst = Math.max(worst, Math.abs(x[i] - y[i]))
      if (!(worst <= 1e-6)) stale.push(`${name}: ${worst} exceeds 1e-6`)
    } else if (name.endsWith('.f64')) {
      // Copied out, because a Buffer may sit at any offset in its pool and a Float64Array may not.
      const doubles = (buffer) => new Float64Array(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength))
      const x = doubles(a)
      const y = doubles(b)
      let worst = x.length === y.length ? 0 : Infinity
      for (let i = 0; i < x.length && worst !== Infinity; i++) worst = Math.max(worst, Math.abs(x[i] - y[i]))
      console.log(`  ${name}: differs from the checked-in render by at most ${worst}`)
      if (!(worst <= AUDIO_TOLERANCE)) stale.push(`${name}: ${worst} exceeds ${AUDIO_TOLERANCE}`)
    } else if (!a.equals(b)) {
      stale.push(`${name}: differs`)
    }
  }
  rmSync(fixtures, { recursive: true, force: true })
  if (stale.length) {
    console.error(`conformance/fixtures is out of date with the driftbox submodule:\n  ${stale.join('\n  ')}`)
    process.exit(1)
  }
  console.log(`fixtures are current with driftbox ${git('rev-parse', '--short', 'HEAD')}`)
  process.exit(0)
}

console.log(`fixtures written from driftbox ${git('rev-parse', '--short', 'HEAD')}: ${SONGS.length} songs${full ? ', with whole-song plans' : ''}`)
