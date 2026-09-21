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
const { planSong } = await import(join(engine, 'schedule.ts'))
const { songBars } = await import(join(engine, 'pattern.ts'))
const { seededRandom } = await import(join(engine, 'render.ts'))
const { Ladder } = await import(join(engine, 'dsp', 'ladder.ts'))

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
  if (decodeSong(text) === null) throw new Error(`${preset.id} does not survive its own codec`)
  write(join(fixtures, 'documents'), `${preset.id}.song.json`, text)
  catalogue.push({ id: preset.id, name: preset.name, blurb: preset.blurb, visual: preset.visual })
}
write(fixtures, 'catalogue.json', json({ songFormat: SONG_FORMAT, songs: catalogue }))

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

// The noise generator, as the integers behind the floats so no decimal printing is involved.
const SEEDS = [1, 0x808, 0x909, 0xdeadbeef, 0]
write(join(fixtures, 'prng'), 'xorshift32.json', json(SEEDS.map((seed) => {
  const next = seededRandom(seed)
  return { seed, first: Array.from({ length: 32 }, () => next() * 0x1_0000_0000) }
})))

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
    if (name.endsWith('.f64')) {
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
