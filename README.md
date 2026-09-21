# Driftbox, native

A native port of [Driftbox](https://github.com/emmettl/driftbox) — a TR-808, a TR-909 and a pair
of TB-303s, synthesised from scratch — for the Mac first, then iOS. Swift throughout.

The web app is the reference implementation and is treated as finished. It is here as a pinned
submodule in `driftbox/`, and nothing in this repository changes it.

**Where this is:** phase 0 of [ROADMAP.md](ROADMAP.md). There is no app yet. There is a harness
that holds Swift to the web engine's behaviour, a package laid out for what comes next, and two
small ports — the 303's ladder filter and the noise generator — that prove the harness end to end.

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
scripts/check-fixtures.sh               # fail if the fixtures are stale against the submodule (emit --check)
swift test
```

Needs Node 24 or later and nothing else: Node strips the types itself, and
`conformance/emit/ts-resolve.mjs` points the reference's `./x.js` imports at the `./x.ts` files
that exist. The submodule is never built or installed.

Three levels, in rising cost:

| Level | Fixture | Compared |
|---|---|---|
| Documents | every catalogue song as the web app saves it | exactly |
| Events | `planSong` for every song — each hit, its time, its resolved knobs and sends; the PRNG as raw bits | exactly |
| Audio | renders of voices, effects and whole songs | within a tolerance |

The first two are what keep two implementations *agreeing*. The third keeps them sounding alike.
Only the ladder has an audio fixture so far; the ones that need a browser to render the reference
(anything built from Web Audio nodes) come with phase 2.

**Songs are data.** `conformance/fixtures/documents` is also the catalogue the app will ship, so
a song added on the web arrives here by bumping the submodule and re-running the emitter. The
diff is the list of what changed, and the tests say what it broke.

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
