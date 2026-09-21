// Renders the reference's audio in a real Chromium and writes it to conformance/generated/audio.
//
//   node conformance/emit/emit-audio.mjs
//
// Not checked in, unlike the fixtures emit.mjs writes: it is tens of megabytes, and Chromium does
// not render the same graph to the same bits twice, so a checked-in copy would be stale against
// itself. CI renders it fresh from the pinned submodule and hands it to the Swift tests.
//
// Every voice is rendered through the reference's own `renderVoiceOffline` — the kit, the builder,
// the trim and the Web Audio graph exactly as a song would use them — so what the Swift renderer
// is compared with is the sound, not a description of it.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { FLOATS_TO_BASE64, floats, openReference } from './browser.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..', '..')
const out = join(root, 'conformance', 'generated', 'audio')

const SAMPLE_RATE = 48000

const DEFAULTS = { level: 0.8, tune: 0.5, decay: 0.5, tone: 0.5, colour: 0.5, pan: 0.5 }
/** Each case is a panel and a velocity. Pan stays centred: these renders are mono. */
const CASES = [
  { name: 'default', params: DEFAULTS, accent: 1 },
  { name: 'soft', params: DEFAULTS, accent: 0.55 },
  { name: 'turned', params: { level: 0.63, tune: 0.81, decay: 0.27, tone: 0.72, colour: 0.88, pan: 0.5 }, accent: 1 },
  // Colour sets a clap's retrigger spacing, and this value puts every retrigger between two sample
  // frames — which is where a renderer has to agree with the browser about rounding.
  { name: 'offgrid', params: { ...DEFAULTS, colour: 0.37 }, accent: 1 },
  // One voice, one panel, kept because the reference gets it wrong — see `theReferenceClicks` in
  // VoiceAudioTests. At colour 0.9 the 808 clap's tail is due 5e-13 of a frame after frame 2160.
  { name: 'boundary', params: { ...DEFAULTS, colour: 0.9 }, accent: 1, only: '808.cp' },
]

const reference = await openReference(join(root, 'driftbox', 'packages'))
try {
  await reference.evaluate(`import('${reference.origin}/engine/src/index.js').then((engine) => { window.engine = engine })`)
  const voices = await reference.evaluate(
    `[...engine.TR808_VOICES, ...engine.TR909_VOICES].map((voice) => voice.id)`,
  )

  rmSync(out, { recursive: true, force: true })
  mkdirSync(join(out, 'voices'), { recursive: true })

  const manifest = []
  for (const id of voices) {
    for (const { name, params, accent, only } of CASES) {
      if (only && only !== id) continue
      // Twice, to measure how far Chromium is from itself on this graph. That number is the floor
      // under any tolerance: nothing can be asked to match the reference more closely than the
      // reference matches itself.
      const [first, second] = await reference.evaluate(`(async () => {
        const voice = [...engine.TR808_VOICES, ...engine.TR909_VOICES].find((voice) => voice.id === ${JSON.stringify(id)})
        const encode = ${FLOATS_TO_BASE64}
        const render = () => engine.renderVoiceOffline(voice, ${JSON.stringify(params)}, ${accent}, ${SAMPLE_RATE})
        return [encode(await render()), encode(await render())]
      })()`)
      const samples = floats(first)
      const again = floats(second)
      let peak = 0
      let selfDifference = 0
      for (let i = 0; i < samples.length; i++) {
        peak = Math.max(peak, Math.abs(samples[i]))
        selfDifference = Math.max(selfDifference, Math.abs(samples[i] - again[i]))
      }
      const file = `voices/${id}.${name}.f32`
      writeFileSync(join(out, file), Buffer.from(samples.buffer))
      manifest.push({ voice: id, case: name, params, accent, sampleRate: SAMPLE_RATE, frames: samples.length, peak, selfDifference, file })
    }
  }

  writeFileSync(join(out, 'voices.json'), `${JSON.stringify({ chromium: reference.product, renders: manifest }, null, 1)}\n`)
  const worst = Math.max(...manifest.map((render) => render.selfDifference))
  console.log(`${manifest.length} voice renders from ${reference.product}; Chromium differs from itself by at most ${worst}`)
} finally {
  await reference.close()
}
