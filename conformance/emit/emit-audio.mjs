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
  // One voice, one panel, kept because the reference used to get it wrong. At colour 0.9 the 808
  // clap's tail is due 5e-13 of a frame after frame 2160; Chromium starts the source on that frame,
  // and until driftbox#297 the gain node was still at its default of 1 there — a one-frame click.
  // The 909 clap did the same on all four retriggers at its *default* panel.
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

  // Probes: one kind of node at a time, outside any voice, so that when a voice differs from the
  // browser there is somewhere smaller to look. Each is a hand-written spec put through the
  // reference's own `renderVoice`.
  const ramp = (decay) => [{ to: 1, at: 0.001, curve: 'lin' }, { to: 0, at: decay }]
  const osc = (type, frequency, extra = {}) => ({ kind: 'osc', type, frequency, gain: 1, amp: ramp(0.3), ...extra })
  const PROBES = {
    'square 80Hz': { duration: 0.35, gain: 0.5, sources: [osc('square', 80)] },
    'square 328Hz': { duration: 0.35, gain: 0.5, sources: [osc('square', 328.4)] },
    'square 1313Hz': { duration: 0.35, gain: 0.5, sources: [osc('square', 1313.13)] },
    'triangle 5100Hz': { duration: 0.35, gain: 0.5, sources: [osc('triangle', 5100)] },
    'sawtooth 220Hz': { duration: 0.35, gain: 0.5, sources: [osc('sawtooth', 220)] },
    'sine 440Hz': { duration: 0.35, gain: 0.5, sources: [osc('sine', 440)] },
    'square 80Hz through a band-pass': { duration: 0.35, gain: 0.5, sources: [osc('square', 80)], filter: { type: 'bandpass', frequency: 9400, Q: 1.4 } },
    'square swept 2000 to 400Hz': { duration: 0.35, gain: 0.5, sources: [osc('square', 2000, { pitch: [{ to: 400, at: 0.1 }] })] },
    'noise through a swept low-pass': { duration: 0.35, gain: 0.5, sources: [{ kind: 'noise', gain: 1, amp: ramp(0.3), filter: { type: 'lowpass', frequency: 8000, Q: 6, envelope: [{ to: 200, at: 0.25 }] } }] },
  }
  mkdirSync(join(out, 'probes'), { recursive: true })
  const probes = []
  for (const [name, spec] of Object.entries(PROBES)) {
    const frames = Math.ceil((spec.duration + 0.05) * SAMPLE_RATE)
    const encoded = await reference.evaluate(`(async () => {
      const encode = ${FLOATS_TO_BASE64}
      const ctx = new OfflineAudioContext(1, ${frames}, ${SAMPLE_RATE})
      engine.renderVoice(ctx, ${JSON.stringify(spec)}, ctx.destination, 0, 'probe')
      return encode((await ctx.startRendering()).getChannelData(0))
    })()`)
    const samples = floats(encoded)
    const file = `probes/${name.replaceAll(' ', '-')}.f32`
    writeFileSync(join(out, file), Buffer.from(samples.buffer))
    probes.push({ name, spec, sampleRate: SAMPLE_RATE, frames, peak: samples.reduce((peak, value) => Math.max(peak, Math.abs(value)), 0), file })
  }
  writeFileSync(join(out, 'probes.json'), `${JSON.stringify(probes, null, 1)}\n`)

  // The waveshaper on its own, with a curve that does nothing: a straight line from -1 to 1. What
  // comes out is then the oversampler and nothing else — its two filters and its delay, measured
  // rather than remembered. An impulse gives the response itself; the sine checks it under load.
  // The third is a real drive curve, through the reference's own `driveCurve` by way of a voice.
  const SHAPER_INPUTS = {
    impulse: `const data = new Float32Array(1024); data[10] = 0.5`,
    sine: `const data = Float32Array.from({ length: 1024 }, (_, i) => 0.8 * Math.sin(i * 0.37))`,
  }
  mkdirSync(join(out, 'shaper'), { recursive: true })
  const shaper = []
  for (const [input, source] of Object.entries(SHAPER_INPUTS)) {
    for (const oversample of ['none', '2x']) {
      const [sent, got] = await reference.evaluate(`(async () => {
        const encode = ${FLOATS_TO_BASE64}
        ${source}
        const ctx = new OfflineAudioContext(1, data.length, ${SAMPLE_RATE})
        const buffer = ctx.createBuffer(1, data.length, ${SAMPLE_RATE})
        buffer.copyToChannel(data, 0)
        const player = ctx.createBufferSource()
        player.buffer = buffer
        const shaper = ctx.createWaveShaper()
        shaper.curve = new Float32Array([-1, 1])
        shaper.oversample = ${JSON.stringify(oversample)}
        player.connect(shaper).connect(ctx.destination)
        player.start(0)
        return [encode(data), encode((await ctx.startRendering()).getChannelData(0))]
      })()`)
      const name = `${input}-${oversample}`
      writeFileSync(join(out, 'shaper', `${name}.in.f32`), Buffer.from(floats(sent).buffer))
      writeFileSync(join(out, 'shaper', `${name}.out.f32`), Buffer.from(floats(got).buffer))
      shaper.push({ name, oversample: oversample === '2x', curve: [-1, 1], input: `shaper/${name}.in.f32`, output: `shaper/${name}.out.f32` })
    }
  }
  writeFileSync(join(out, 'shaper.json'), `${JSON.stringify(shaper, null, 1)}\n`)

  // Every voice again, panned, into a stereo context — the mono renders above cannot tell left
  // from right. Interleaved. The panel is off centre on purpose: at exactly centre the reference
  // builds no panner at all, which is 3dB louder than a panner at centre would be, and the
  // 'default' case above already covers that path.
  mkdirSync(join(out, 'stereo'), { recursive: true })
  const stereo = []
  for (const id of voices) {
    const params = { ...DEFAULTS, pan: 0.2 }
    const encoded = await reference.evaluate(`(async () => {
      const encode = ${FLOATS_TO_BASE64}
      const voice = [...engine.TR808_VOICES, ...engine.TR909_VOICES].find((voice) => voice.id === ${JSON.stringify(id)})
      const spec = { ...voice.build(${JSON.stringify(params)}, 1), ...(voice.trim === undefined ? {} : { trim: voice.trim }) }
      const frames = Math.max(1, Math.ceil((spec.duration + 0.05) * ${SAMPLE_RATE}))
      const ctx = new OfflineAudioContext(2, frames, ${SAMPLE_RATE})
      engine.renderVoice(ctx, spec, ctx.destination, 0, voice.id)
      const buffer = await ctx.startRendering()
      const left = buffer.getChannelData(0), right = buffer.getChannelData(1)
      const interleaved = new Float32Array(frames * 2)
      for (let i = 0; i < frames; i++) { interleaved[i * 2] = left[i]; interleaved[i * 2 + 1] = right[i] }
      return encode(interleaved)
    })()`)
    const samples = floats(encoded)
    const file = `stereo/${id}.f32`
    writeFileSync(join(out, file), Buffer.from(samples.buffer))
    stereo.push({ voice: id, case: 'panned', params, accent: 1, sampleRate: SAMPLE_RATE, frames: samples.length / 2, peak: samples.reduce((peak, value) => Math.max(peak, Math.abs(value)), 0), file })
  }
  writeFileSync(join(out, 'stereo.json'), `${JSON.stringify({ renders: stereo }, null, 1)}\n`)

  writeFileSync(join(out, 'voices.json'), `${JSON.stringify({ chromium: reference.product, renders: manifest }, null, 1)}\n`)
  const worst = Math.max(...manifest.map((render) => render.selfDifference))
  console.log(`${manifest.length} voice renders from ${reference.product}; Chromium differs from itself by at most ${worst}`)
} finally {
  await reference.close()
}
