# Driftbox, native

A native port of [Driftbox](https://github.com/emmettl/driftbox): a groovebox of a TR-808, a
TR-909 and a pair of TB-303s, synthesised from scratch, and a modular rack to patch them into.
Swift throughout, with no dependencies in the audio. The Mac comes first; Windows, Android and
Linux build from the same sources.

The web app is the reference implementation and is treated as finished. It is here as a pinned
submodule in `driftbox/`, and nothing in this repository changes it. The native engine is held to
it by measurement: songs decode, plan and sound as the browser's do, within bounds set out in
[docs/conformance.md](docs/conformance.md).

The project's website is at <https://emmettl.github.io/driftbox-native/>.

## Where it stands

- **Mac.** The groovebox and its editor; the rack in a window of its own; all twenty-seven of the
  web's scenes, in a pane or full screen on another display; MIDI in and clock out; Audio Units
  hosted in the rack, and the rack and the groovebox as AUv3 instruments for other apps; movie
  export and performance recording; and the guides and guided tours. Releases are signed and
  notarised locally. See [docs/mac.md](docs/mac.md).
- **Windows.** The same app, drawn on the GPU layer: groovebox, rack, visuals, guides and tours,
  VST 3 plug-ins in the rack, movies, and screen reader support through UI Automation. A zip and
  an installer, built by the release workflow on a tag; code signing through the SignPath
  Foundation is wired in and awaits their approval. See [docs/windows.md](docs/windows.md).
- **Android.** A touch app on the same sessions: the groovebox, the rack, the scenes, guides and
  tours, MIDI, and songs through Android's own pickers. The APK and App Bundle are ready for a
  store, and not yet published. See [docs/android.md](docs/android.md).
- **Linux.** A preview: the shared desktop app on GTK 4, OpenGL ES, Pango, PipeWire and ALSA MIDI.
  CI builds a tarball and `.deb` packages for Ubuntu 24.04 on ARM64 and x86-64; it is not yet
  qualified for release. See [docs/LINUX.md](docs/LINUX.md) and [linux/README.md](linux/README.md).
- **iOS** waits until the Mac app is done.

[ROADMAP.md](ROADMAP.md) has what is left, milestone by milestone.

## Building on the Mac

Swift 6.4 and macOS 26. The fixtures are checked in; regenerating them needs the submodule
checked out, Node 24 or later, and a Chromium.

```bash
scripts/bundle-app.sh && open .build-release/Driftbox.app       # the app, with its AUv3 extension
swift run -c release driftbox-play conformance/fixtures/documents/acid.song.json
swift run -c release driftbox-render conformance/fixtures/documents/smallhours.song.json out.wav
```

`driftbox-play` plays a song through the speakers (`--window` shows its scene, `--bench` measures
the render), and `driftbox-render` writes one to a WAV file; see
[docs/performance.md](docs/performance.md).

| Platform | How to build it |
|---|---|
| Windows | [docs/windows.md](docs/windows.md) |
| Android | [docs/android.md](docs/android.md) |
| Linux | [docs/LINUX.md](docs/LINUX.md), and `scripts/linux-build.sh` |
| Releases | [docs/RELEASING.md](docs/RELEASING.md) (Mac and Android), [CODE_SIGNING.md](CODE_SIGNING.md) (Windows) |

## Layout

| | |
|---|---|
| `driftbox/` | The web repository, pinned: the reference. |
| `conformance/` | The emitter that runs the reference and the fixtures it writes. |
| `Sources/DriftboxDSP`, `DriftboxSeq`, `DriftboxEngine`, `DriftboxRack` | The audio core: filters and oscillators, songs and what they play, the instruments and effects, the modular rack. **Constrained**: no Foundation, no platform, no allocation on the render path. |
| `Sources/DriftboxDocument` | The song codec, byte for byte with the web's documents, and the catalogue. |
| `Sources/DriftboxHost` | The engine and rack hosts, and the ports each platform's audio and MIDI sits behind. |
| `Sources/DriftboxHostMac`, `…Windows`, `…Android`, `…Linux` | Each platform's audio and MIDI behind those ports. |
| `Sources/DriftboxSession`, `DriftboxRackSession` | The groovebox and the rack as an app holds them, on every platform. |
| `Sources/DriftboxScenes`, `DriftboxGPU*`, `DriftboxCanvas`, `DriftboxText*` | The visuals, the GPU layer and its backends, a 2D canvas, and type. |
| `Sources/DriftboxInterface`, `DriftboxDesktop`, `DriftboxTouch` | The drawn interface, on a desktop window and on a touch screen. |
| `Sources/DriftboxApp`, `Driftbox`, `DriftboxAudioUnits` | The Mac app, its executable, and its AUv3 extension. |
| `Sources/DriftboxWindows`, `DriftboxAndroid`, `driftbox-linux` | The Windows, Android and Linux apps. |
| `shaders/` | Every shader, written once in GLSL. |

[docs/architecture.md](docs/architecture.md) has every target, the layers, the ports and the shared
sessions.

## Testing

```bash
SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6 swift test
swift format lint --strict -r Sources Tests Package.swift
scripts/check-constrained.sh     # the audio core compiles as Embedded Swift, with no allocation
scripts/check-fixtures.sh        # the fixtures are not stale against the submodule
```

- **Conformance.** The reference's own TypeScript writes fixtures (documents, event plans, edits,
  MIDI clock, voice descriptions, rack graphs and panels, and audio rendered in Chromium), and the
  Swift is held to them: exactly where the data is data, and within -75 to -100dB of the browser
  where it is sound. [docs/conformance.md](docs/conformance.md) has the levels, the commands, and
  what was learned by measuring.
- **Strict isolation.** The variable makes `swift test` check actor isolation as strictly as the app
  does. Without it, a closure made on the main actor and called from an audio or MIDI thread traps
  in the app while every test passes.
- **Every platform.** CI runs the suite on Linux and on Windows, builds the Android app, and builds
  and checks the Linux packages. The Mac's suite runs locally, and before every release. Checks
  that need a phone run on one, or an arm64 emulator, through `scripts/android-app.sh`.

## Documentation

- [docs/architecture.md](docs/architecture.md): the targets, the constrained core, the ports, the
  shared sessions, conventions.
- [docs/conformance.md](docs/conformance.md): the fixtures, the audio against the browser, the
  offline and real-time forms, exactness.
- [docs/gpu.md](docs/gpu.md): the GPU layer, its backends and shaders, type, and the canvas.
- [docs/visuals.md](docs/visuals.md): the scenes, how they are fed and tested.
- [docs/performance.md](docs/performance.md): playing, rendering, and what the render costs.
- [docs/mac.md](docs/mac.md), [docs/windows.md](docs/windows.md),
  [docs/android.md](docs/android.md), [docs/LINUX.md](docs/LINUX.md): each platform.
- [docs/RELEASING.md](docs/RELEASING.md) and [CODE_SIGNING.md](CODE_SIGNING.md): releases.
- [ROADMAP.md](ROADMAP.md): what is done and what is next.

## Licence

[MIT](LICENSE), as the web app is. Use it, embed it, sell what you build with it: the engine is
meant to be picked up, and that is the licence that gets least in the way of doing so.

Steinberg's VST 3 SDK, in `Sources/VST3SDK` and `Tests/DriftboxVST3Fixture`, is theirs, under
[its own MIT licence](Sources/VST3SDK/LICENSE-VST3SDK.txt). VST is a trademark of Steinberg Media
Technologies GmbH.
