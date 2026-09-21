# Driftbox, native

A native port of [Driftbox](https://github.com/emmettl/driftbox) — a TR-808, a TR-909 and a pair
of TB-303s, synthesised from scratch — for the Mac first, then iOS. Swift throughout.

The web app is the reference implementation and is treated as finished. It is here as a pinned
submodule in `driftbox/`, and nothing in this repository changes it.

**Where this is:** phase 2 of [ROADMAP.md](ROADMAP.md) is under way. There is no app yet. There is
a harness that holds Swift to the web engine's behaviour, and behind it: a song model, a codec that
reads and writes the web app's documents to the byte, a sequencer that plans every catalogue song
exactly as the reference does, and the instruments: all 22 drum voices — as data, exactly, and as
sound, within -100dB of the browser's — and the 303 (looser where there are square waves, drive or
a resonant ladder, for reasons given below).

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
| Audio | each voice rendered in Chromium, over four panels, and again panned in stereo; nine probes of one node type each; the waveshaper alone | within -100dB of the peak; -90dB through drive; -75dB with square or sawtooth oscillators |

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
| through drive (the 909 kick, snare and clap) | -98 to -131dB |
| 303 lines from the catalogue: slides, accents, ties | -94 and -116dB sawtooth, -85dB square |
| the delay send: settled, gliding, and retimed mid-tail | -139 to -142dB |
| the reverb send, three rooms | -112 to -131dB |
| the browser's compressor alone, three settings | -125 to -138dB |
| the master inserts whole: drive, struck filter, compressor | -94 to -136dB; -63dB after one kind of strike |
| the performance filter: idle, and through three gestures | -141dB idle; -78 to -98dB moving |
| the oversampler alone, against its measured impulse response | under 1e-6 |
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
- **Cancelling a ramp snaps back; it does not hold.** Every 303 note cancels what was scheduled
  before it, and a filter sweep still under way is a ramp due in the future, so it goes. In the
  browser the parameter then jumps back to where the ramp *started* — the last thing the timeline
  still knows — rather than holding where it had got to. `ParamTimeline.cancel` does the same, and
  takes the moment the call is made, because what had already played stays played. The reference's
  mix schedules each note from the start of its render quantum, so its filter snaps open for up to
  127 frames before a note; a sequencer that schedules to the sample, as this one will, has no
  such window. (Scheduled all up front, as the reference's *stem* export does, every overlapped
  sweep is cancelled before it plays at all — a bug there, reported.)
- **An idle filter is not an absent one.** The performance pad is a low-pass into a high-pass,
  both "wide open" when nobody is touching it, and the reference calls that a true bypass. Sample
  for sample its output differs from its input by nearly the whole signal: a 20Hz high-pass turns
  the phase of the bass, and a 20kHz low-pass shaves the top. Nobody hears it, and every mix the
  reference has ever rendered went through it — so `Kaoss` is in the chain here too, idle, and
  matches at -141dB.
- **A glide arrives at ten time constants, not after them.** `setTargetAtTime` never finishes on its
  own, so the browser declares it finished — and a glide of 0.02s begun on a render quantum is ten
  time constants old on another one exactly. "After" is a quantum late, which on a resonant filter
  was the difference between -56 and -78dB.
- **The compressor has no specification, only an implementation.** The standard names the
  `DynamicsCompressorNode`'s knobs and says nothing of how it behaves, so "the compressor" in the
  reference is Chromium's, inherited from WebKit, and the songs were mixed through it. `Compressor`
  follows it move for move: six milliseconds of look-ahead, a soft knee whose steepness is found by
  bisection, makeup gain that is automatic (quiet signals come out 1.7 times louder), a detector
  that follows attenuation rather than level, gain that moves in 32-frame steps with a release
  that is faster the harder it was compressing, and a sine on the way out to round the corners. It
  also starts with its detector at zero, so the first fifty milliseconds of any render duck and
  recover. Written from the algorithm and then measured: -125 to -138dB on the first run.
- **Turning the drive up from zero moves the mix 2.7ms later.** At zero the master waveshaper has
  no curve, and passes the signal straight through: the chain is then bit-identical to the
  compressor alone. With any drive it oversamples, and brings its 128 frames of delay.
- **One thing here is not understood.** A filter strike that arrives while the sweep before it is
  still running matches the browser to -63dB for a quarter of a second, where a strike that finds
  the filter at rest matches to -120dB. Snapping back to the cancelled sweep's peak is certainly
  most of what the browser does — holding is 18dB worse, snapping elsewhere 44dB worse — and the
  rest is unexplained. No catalogue song strikes the filter.
- **A delay in a loop is 128 frames longer than it says, every time round.** The browser computes
  a feedback loop a render quantum at a time, and the way it breaks the cycle hands the filter the
  delay's output from the quantum before. So the second repeat of the reference's delay lands 128
  frames late, the third 256: a dotted-eighth echo drifts 2.7ms further off the grid with each
  repeat, and always has. Kept.
- **A delay line is read in single precision, which is coarse.** The read position is a 32-bit
  float of magnitude a hundred thousand or so, which resolves to a sixty-fourth of a frame. A delay
  of 17142.857 frames is read at 17142.859, and an impulse comes back as exactly 9/64 and 55/64 of
  itself. Doing the arithmetic properly, in double precision, matched to -53dB; doing it the
  browser's way, -142dB. (For a while this looked like the delay time being read once per quantum,
  because two neighbouring frames kept rounding to the same fraction. It is read every frame.)
- **The reference does not agree with itself across processors, and that sets the bounds.** An
  x64 Chrome and an arm64 Chrome render most of this to within -100dB of each other — but x64
  steps `setTargetAtTime` four frames at a time with differently rounded arithmetic, so while a
  delay time is gliding the two browsers differ by **-19dB** on a click through the delay. This
  renderer matches the arm64 one to -140dB. Nothing can be held to a reference more tightly than
  the reference holds to itself, so those cases carry the browsers' own disagreement as their
  bound, and a second check — the level of every stretch of the tail, which both browsers agree
  on to 0.3dB — holds the shape of the glide instead.
- **`setTargetAtTime` is stepped, not solved.** A single-precision value moved towards its target
  once per frame, which after seventeen thousand steps is a sixteenth of a sample from the closed
  form — and that is where the echo lands while a delay time is gliding.
- **The waveshaper delays by 128 frames, and that is kept.** The browser oversamples drive with
  two windowed-sinc filters, and they are audible: they ring a little either side of a transient
  and they hold the signal back 2.7ms. A 909 kick in the reference has always landed that far
  behind an 808 kick on the same step. `WaveShaper` has the same filters, checked against the
  browser's impulse response measured through a curve that does nothing.
- **A voice gets quieter the moment its pan knob leaves centre.** The reference builds a panner only
  when the pan is not exactly centre, so a centred voice goes to both sides at full level where a
  panner at centre would put it 3dB down. The songs were mixed that way, so it is kept.
- **The reference clicked, and no longer does.** At some knob settings a source is due a sliver of
  a frame after a frame boundary; Chromium starts it on that frame, and the gain envelope's first
  event was still in the future, so the `GainNode` sat at its default of 1 for one frame. It was
  found here on the 808 clap at one setting — and then on the 909 clap at its *default* panel, all
  four retriggers. Fixed in driftbox#297; this renderer never reproduced it, and the case that
  found it is now an ordinary one that matches at -141dB.

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
