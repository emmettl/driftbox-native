# Driftbox, native

A native port of [Driftbox](https://github.com/emmettl/driftbox) — a TR-808, a TR-909 and a pair
of TB-303s, synthesised from scratch — for the Mac first, then iOS. Swift throughout.

The web app is the reference implementation and is treated as finished. It is here as a pinned
submodule in `driftbox/`, and nothing in this repository changes it.

**Where this is:** phase 2 of [ROADMAP.md](ROADMAP.md) is under way. There is no app yet. There is
a harness that holds Swift to the web engine's behaviour, and behind it: a song model, a codec that
reads and writes the web app's documents to the byte, a sequencer that plans every catalogue song
exactly as the reference does, all 22 drum voices as data, and a renderer that so far turns 19 of
them into sound within -100dB of the browser's (-75dB where there are square waves, for a reason
given below).

## Layout

| | |
|---|---|
| `driftbox/` | The web repository, pinned. The reference for everything below. |
| `conformance/emit/` | Runs the reference TypeScript as it stands and writes fixtures from it. |
| `conformance/fixtures/` | What the Swift tests are held to. Checked in. |
| `Sources/DriftboxDSP` | Filters, oscillators, envelopes, noise. **Constrained.** |
| `Sources/DriftboxSeq` | What a song is and what it decides to play. **Constrained.** |
| `Sources/DriftboxEngine` | The instruments, mixer and effects behind one `render`. **Constrained.** |
| `Sources/DriftboxDocument` | The song codec, migrations, shareable URLs, the catalogue. |
| `Sources/DriftboxHost` | The audio unit, the rings to and from the render thread, MIDI. |

## The constrained targets

The three audio targets take nothing from outside themselves: no Foundation, no platform, no
dependencies. They do not allocate, lock, or touch a class or an existential on the render path.
That is what makes them safe on a real-time thread and what makes a render a function of the
song and nothing else.

The compiler checks it, in two halves, because neither half is enough alone:

```bash
scripts/check-constrained.sh
```

1. They compile as **Embedded Swift** for a bare WebAssembly target. That rules out Foundation,
   reflection and the platform. It does *not* rule out existentials — Embedded Swift accepts
   `any P` as of 6.3, which was measured rather than assumed.
2. Every function on the render path is marked **`@_noAllocation`**, and an optimised build
   turns an allocation, an existential or a class instance inside one into an error.

The Embedded half needs a swift.org toolchain, since Xcode's ships no Embedded standard library.
The script finds `~/Library/Developer/Toolchains/swift-latest.xctoolchain`, or takes
`DRIFTBOX_EMBEDDED_SWIFTC`.

The one thing the DSP takes from outside is `exp` and `tanh` from the C library
(`Sources/DriftboxDSP/Math.swift`). See "Exactness" below.

## Conformance

```bash
node conformance/emit/emit.mjs          # rewrite the checked-in fixtures
node conformance/emit/emit.mjs --full   # also whole-song plans, into conformance/generated
node conformance/emit/emit-audio.mjs    # every voice rendered in Chromium, into conformance/generated
scripts/check-fixtures.sh               # fail if the fixtures are stale against the submodule (emit --check)
swift test
```

Needs Node 24 or later and, for the audio, a Chromium — and nothing else. Node strips the types
itself, and `conformance/emit/ts-resolve.mjs` points the reference's `./x.js` imports at the
`./x.ts` files that exist. The submodule is never built or installed.

The audio step drives a real browser because only a real `OfflineAudioContext` renders the
reference's Web Audio graph. `conformance/emit/browser.mjs` does it in two small pieces: an HTTP
server that serves the submodule's TypeScript with its types stripped on the way out, and the
DevTools protocol over Node's built-in WebSocket. It finds `DRIFTBOX_CHROMIUM`, then a Playwright
cache, then an installed Chrome.

What lands in `conformance/generated` is not checked in: it is tens of megabytes, and Chromium does
not render one graph to the same bits twice. Tests that need it skip when it is absent — except
under `DRIFTBOX_REQUIRE_GENERATED`, which CI sets after generating it, so that there a missing
fixture is a failure.

Three levels, in rising cost:

| Level | Fixture | Compared |
|---|---|---|
| Documents | every catalogue song as the web app saves it; 19 damaged and legacy documents with what the reference makes of each | exactly |
| Events | `planSong` for every song — each hit, its time, its resolved knobs and sends; three deliberately awkward songs; the PRNG as raw bits | exactly |
| Voices | what each of the 22 voices *describes* — its `VoiceSpec` — over nine panels and both velocities | exactly |
| Audio | each voice rendered in Chromium, over four panels; nine probes of one node type each | within -100dB of the peak; -75dB with square or sawtooth oscillators |

**Documents** go both ways: a catalogue song decodes and encodes back to the same bytes, which
needs object keys kept in document order and numbers printed as JavaScript prints them —
`Sources/DriftboxDocument/JSONValue.swift` exists for those two things. The damaged documents pin
down the repairs: a v1 chain, halves that round the way `Math.round` does, a bad step costing the
step and not the track.

**Events** check in the first four bars of each song. `--full` writes whole songs, and the same
test walks them start to finish when they are there. The catalogue uses no machine clips, short
drum lanes, flams or filter strikes, so `events/synthetic.json` holds songs written to be awkward:
all of those at once, bars of three different lengths, tempo and swing under automation, a voice
no machine owns, and clips launched over the top.

The first two are what keep two implementations *agreeing*. The third keeps them sounding alike.
Only the ladder has an audio fixture so far; the ones that need a browser to render the reference
(anything built from Web Audio nodes) come with phase 2.

**Songs are data.** `conformance/fixtures/documents` is also the catalogue the app will ship, so
a song added on the web arrives here by bumping the submodule and re-running the emitter. The
diff is the list of what changed, and the tests say what it broke.

**Voices** are split the way the reference splits them. A voice is a function from its panel to a
description of a sound, and the description is data, so all 396 compare exactly. With that pinned,
any difference in the *sound* belongs to the one renderer and not to 22 voices.

**Audio** is that renderer against the browser. Measured, relative to each voice's peak:

| | |
|---|---|
| noise through filters, resampled or not | -120 to -142dB — a step or two of a 32-bit float |
| sines and triangles | -104 to -125dB |
| squares and sawtooths | -78 to -116dB |
| Chromium against itself | up to 5e-7 between two renders of one graph |

`probes.json` holds one kind of node at a time, outside any voice — a bare square, a swept filter —
so that when a voice differs there is somewhere smaller to look. Most of what follows was found
there. Things learned by measuring rather than reading:

- **A source starts when it is told to, not on the next frame.** A clap's retriggers fall between
  sample frames, and the browser begins each one a fraction of a frame in, interpolating the noise.
  Rounding them to a frame is a whole sample out, and two copies of one noise a sample apart is a
  comb filter: -11dB, not -140.
- **The browser's parameters are single precision, and it matters twice.** An oscillator's phase
  step is a 32-bit product; matching that took the cowbell from -85dB to -106dB. A buffer's
  playback rate is a 32-bit float; matching that took the 909 crash — two seconds of resampled
  noise — from -61dB to -131dB. Neither is audible as pitch. Both are the same few parts in a
  hundred million *in the same direction*, and drift is what a subtraction hears.
- **Oscillators are wavetables, and the tables are the sound.** `WaveTable` follows Chromium's
  `PeriodicWave` step for step — table size, three ranges to the octave, how many partials each
  keeps, normalised by the peak of the fullest table, Gibbs overshoot and all. Triangles match to
  -109dB and better. Squares stop at about -80dB: what is left is a timing difference of a
  hundred-thousandth of a sample in where the table is read, which a waveform with edges spreads
  evenly over every harmonic. That is the browser's arithmetic, a nanosecond, and not chased
  further.
- **The reference clicks, rarely.** See `theReferenceClicks` in `VoiceAudioTests`: at one knob
  setting the 808 clap's tail is due 5e-13 of a frame after a frame boundary, Chromium starts the
  source on that frame, and the gain envelope's first event is still in the future — so the
  `GainNode` is at its default of 1 for one frame. This renderer does not reproduce it.

The renderer is being built one kind of node at a time, each measured before the next. It says
what it cannot render yet (`VoiceRenderer.unsupported`) rather than rendering something close:
today that is the oversampled waveshaper — the 909's kick, snare and clap — and pan. The test lists
the voices still waiting, so one can only leave that list by being compared.

### Exactness

The Swift ladder is the reference's arithmetic line for line, with `Double` state because
JavaScript computes in doubles whatever it stores. Against the fixture it differs by **1.8e-15**
at double precision — not zero, because `exp` and `tanh` come from two different maths libraries
(V8's and the platform's), and a resonant loop feeds a last-bit disagreement back. The test
allows 1e-12. On Linux, against glibc, it passes inside the same bound.

**The reference does not agree with itself, either.** The same TypeScript rendering the same
ladder gives different last bits under Node on an arm64 Mac and on an x64 Linux runner — found
when the first CI run called a freshly generated fixture stale. Documents, events and PRNG bits
did come out byte-identical across the two, so `--check` holds text fixtures to the byte and audio
fixtures to the same 1e-12.

Writing `exp` and `tanh` in Swift would make every native render bit-exact on every platform;
that is worth doing when a second one needs to agree.

## Conventions

Swift 6.4, Swift Testing, `swift format` (config in `.swift-format`; CI lints with `--strict`).
macOS 15 and iOS 18 are the floors.
