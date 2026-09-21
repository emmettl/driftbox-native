# Roadmap

Three milestones. The first two are parity with the web app; the third is the reason to have
gone native at all.

## Decisions already made

- **Pure Swift, one repository, the web app untouched.** The web side is finished bar new songs
  and scenes. It is a fixed reference, which is what makes a second engine affordable: tests can
  say Swift has fallen behind, and the thing it is behind has stopped moving.
- **The audio lives in constrained packages** — see the README. Zero dependencies, nothing on the
  render path that allocates.
- **The Mac first, then iOS.**
- **Sound matches the web by measurement** wherever the Web Audio specification gives formulas:
  biquads, parameter ramps, the panner, delays. The compressor and the 303's oscillator tables
  have no specification to match and are tuned by ear.
- **Visuals carry the intent, not the pixels.** A scene keeps its id, so a song's `visual` hint
  resolves on both platforms, and keeps what it is *about*. The implementation is free to
  surpass the web's, and doing what a browser cannot is part of the point. Judged by eye.
- **Private until the parity and quality goals are met.** Then public, with notarised builds,
  and the App Store considered.

## Milestone 1 — the groovebox

0. ~~**Harness and skeleton.**~~ Done. The submodule, the emitter, the package, the constraint
   checks, CI.
1. ~~**Seq and Document.**~~ Done. Every catalogue song decodes, encodes back to the same bytes,
   and plans identically to `planSong`, whole. No sound. What it left for later: `planStep` is the
   faithful form and builds arrays as it goes, so it is not what the render thread will call —
   phase 4 plans from a song compiled ahead of time into indices and fixed storage, and checks
   that against this. The editing half of `pattern.ts` arrives with the editor.
2. **DSP and the drum voices.** ← *here.* Done so far: the browser-rendered reference, the
   parameter timeline, the biquad, all 22 voices as data (exact), and a renderer for wavetable
   oscillators, noise (resampled too), envelopes and filters — 19 voices, within -100dB of
   Chromium, or -75dB where there are squares. Still to come: the 2x-oversampled waveshaper, which
   is the 909's kick, snare and clap, and pan. Then a listening pass.
   What was planned: `ParamTimeline` — the Web Audio automation calls, per sample —
   then biquad, oscillator, noise, and the `VoiceSpec` interpreter. The 22 voices are data handed
   to one interpreter, so this is one interpreter and a set of small functions rather than 22
   synths. Done when each voice renders within tolerance of the browser, and a listening pass.
3. **The 303s, strips, sends, master, the performance filter.** Done when whole songs match
   `renderMix` by spectral fingerprint.
4. **A real-time host on the Mac.** `AUAudioUnit` from the start, sequencing sample-accurately
   inside the render block, lock-free rings both ways. The ring back to the interface carries
   *events* — which voice, accents, slides, sections — not only levels, so scenes can react to
   what was played rather than to a spectrum. Done when a bare player plays the catalogue.
5. **The editor.** Sequencer, voice and bass panels, pattern tools, arrangement, effects, the
   pad, the library, keys. Document-based, undo, CoreMIDI including clock follow, stems.
6. **Visuals.** A thin Metal layer — lines, instanced meshes, full-screen and compute passes —
   and the scenes reinterpreted one at a time, with a fallback for any a song names that has not
   landed. Needs only the ring from phase 4, so it runs alongside phase 5.
7. **iOS.** Audio session, background audio, a layout that opens into the visuals, haptics,
   Now Playing, and the AUv3 extension the phase 4 audio unit already is.

## Milestone 2 — the rack

The 49 modules, ported against `RackRenderer`, which runs in Node with no browser — so these
fixtures can be far tighter than the groovebox's. Then the cables and faceplates. This is the
parity point, and close to done.

## Milestone 3 — what only native can do

Plug-in hosting (Audio Units first, which work on iOS too; VST3 on the Mac), AUv3 export,
external displays, performance capture to video.

### What the later milestones ask of the first

Small now, costly later:

- **The groovebox is a rack device from the start**: per-machine stereo outputs with strip
  parameters, the shape of `GROOVEBOX_PORTS` on the web. In milestone 2 it becomes one node.
- **Blocks, with a reported latency.** Nothing assumes a per-sample callback, and every
  processor says how late it is. Hosted plug-ins need exactly this.
- **Plug-in hosting lives in `DriftboxHost`**, never in the constrained targets. The graph gets
  an "external processor" node and the host fills it in.
- **Documents carry opaque state for external nodes**, and degrade to a placeholder when the
  plug-in is missing.
