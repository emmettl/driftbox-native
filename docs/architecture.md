# Architecture

How the repository is divided, what each part may depend on, and what is shared between the
platforms. The per-platform details are in [mac.md](mac.md), [windows.md](windows.md),
[android.md](android.md) and [LINUX.md](LINUX.md); the GPU layer, type and the canvas are in
[gpu.md](gpu.md).

## Layers

What the rest of Driftbox asks of a platform is written down once, in `DriftboxHost` and a few
small targets beside it, and each platform answers it in a target of its own:

```
the apps           DriftboxApp (Mac), DriftboxWindows, DriftboxAndroid, driftbox-linux
shared interface   DriftboxDesktop, DriftboxTouch, DriftboxInterface, DriftboxHelp
sessions           DriftboxSession (the groovebox), DriftboxRackSession (the rack)
adapters           DriftboxHostMac: AVAudioEngine, Core MIDI, Audio Units
                   DriftboxHostWindows: WASAPI, WinMM      DriftboxHostAndroid: AAudio, AMidi
                   DriftboxHostLinux: PipeWire, ALSA
ports              DriftboxHost: AudioRouting, MIDIInputPort, MIDIOutputPort, HostTime, RenderSource
                   DriftboxShell, DriftboxText, DriftboxGPU
hosts              DriftboxHost: EngineHost, RackHost, the rings, the Mixer
documents          DriftboxDocument
constrained core   DriftboxDSP, DriftboxSeq, DriftboxEngine, DriftboxRack
```

Dependencies point down and never across: nothing platform-neutral imports a platform, and no
adapter knows another exists. `Package.swift` says so too: a platform's adapter depends on its C
headers only when building for that platform, and its sources compile to nothing anywhere else.

## Targets

### The reference and its fixtures

| | |
|---|---|
| `driftbox/` | The web repository, pinned. The reference for everything below. |
| `conformance/emit/` | Runs the reference TypeScript as it stands and writes fixtures from it. |
| `conformance/fixtures/` | What the Swift tests are held to. Checked in. See [conformance.md](conformance.md). |

### The core and the hosts

| | |
|---|---|
| `Sources/DriftboxDSP` | Filters, oscillators, envelopes, noise. **Constrained.** |
| `Sources/DriftboxSeq` | What a song is and what it decides to play. **Constrained.** |
| `Sources/DriftboxEngine` | The instruments, mixer and effects behind one `render`. **Constrained.** |
| `Sources/DriftboxRack` | The modular rack: the patch compiler, the graph, the modules. **Constrained.** |
| `Sources/DriftboxDocument` | The song codec, migrations, shareable URLs, the catalogue, and `SongFile`, the rule for `.driftbox` names. |
| `Sources/DriftboxHost` | The engine and rack hosts, the rings to and from the render thread, the ports every platform's audio and MIDI sits behind, and the mixer every platform's output renders through. |

### Platform adapters

| | |
|---|---|
| `Sources/DriftboxHostMac` | Core Audio and Core MIDI behind the ports, and Audio Units: the engine as a unit for `driftbox-play`, the rack and the groovebox as the extension's instruments, and units hosted in the rack. |
| `Sources/DriftboxHostWindows` | WASAPI and WinMM behind the ports. |
| `Sources/DriftboxHostAndroid` | AAudio and native MIDI behind the ports. |
| `Sources/DriftboxHostLinux` | PipeWire and the ALSA sequencer behind the ports. |
| `Sources/DriftboxHostVST3` | The rack's VST 3 plug-ins: found, each a `plugin` module's unit, played, with its macros and its state. Windows only. |
| `Sources/DriftboxVST3Scan` | Asks a VST 3 module what it holds, in a process of its own, so that a plug-in that crashes as it loads takes this with it rather than the app. |
| `Sources/CVST3` | Driftbox's bridge to VST 3 plug-ins, in C for Swift: a plug-in found, made, played, its parameters set, its state kept, and its own editor opened in a window. `Tests/DriftboxVST3Fixture` is a plug-in of the project's own to hold it to. |
| `Sources/VST3SDK` | Steinberg's VST 3 SDK, as much of it as a host uses, vendored at 3.8.1 under its own MIT licence. |
| `Sources/CWASAPI`, `CDirectWrite`, `CShellDialogs` | Windows headers that Swift's WinSDK module leaves out, or that are C++ only. Declarations only. |
| `Sources/CAAudio`, `CAMidi`, `CLooper`, `CMedia` | Android NDK headers that the Swift SDK's Android module leaves out. Declarations only. |
| `Sources/CPipeWire`, `CALSA`, `CGTK` and their bridges, `CLinuxUI` | Linux system libraries, found through `pkg-config`, and the small C that sits between them and Swift. |
| `Sources/CGLES` | EGL's and OpenGL ES 3.0's headers. Declarations only. |
| `Sources/CAccessibility` | The drawn controls for screen readers: a UI Automation provider in C++, fed the tree the app describes. Windows only. |

### What an app holds

| | |
|---|---|
| `Sources/DriftboxSession` | The groovebox as an app holds it, on every platform: the song, the transport, editing and undo, the MIDI clock both ways, what is remembered, and the catalogue. |
| `Sources/DriftboxRackSession` | The rack as an app holds it, on every platform: the patch, its edits and undo, the keys, controllers, samples, song and transport, the catalogue of patches, and the guided tours; audio, plug-ins and file reading behind ports. |
| `Sources/DriftboxHelp` | The groovebox's and the rack's guides, as words any platform lays out, in each platform's terms. |
| `Sources/DriftboxExtensions` | The rack and the groovebox inside another app: a `RackSession` and a `Session` behind their Audio Units, made at the host's rate, with their presets, state, MIDI, the host's clock and their parameters, and their faces on the same sessions. |

### Visuals, type and drawing

| | |
|---|---|
| `Sources/DriftboxScenes` | The visuals: the analyser, the Metal scenes the Mac app draws, and every scene again on the GPU layer. See [visuals.md](visuals.md). |
| `Sources/DriftboxGPU` | What the scenes ask of a GPU, as a protocol every backend answers the same way. See [gpu.md](gpu.md). |
| `Sources/DriftboxGPUMetal`, `DriftboxGPUD3D11`, `DriftboxGPUGLES` | That protocol on Metal (Mac), Direct3D 11 (Windows) and OpenGL ES 3.0 (Android and Linux). |
| `shaders/` | The GLSL every shader is written in, once. `scripts/shaders.mjs` makes each backend's language from it. |
| `Sources/DriftboxText` | What the app asks of a platform's type: a line set in a font, and a glyph's coverage. |
| `Sources/DriftboxTextMac`, `DriftboxTextWindows`, `DriftboxTextAndroid`, `DriftboxTextLinux` | That on Core Text, DirectWrite, Android's own text stack, and Pango. |
| `Sources/DriftboxCanvas` | A 2D canvas on the GPU layer: Canvas2D's shapes, state, type and blends, the same on every platform. |
| `Sources/DriftboxMovie` | A performance and its visuals as a movie, on every platform with the GPU layer, handed to the platform's writer. `Sources/CMovieWriter` is that writer on Windows, through Media Foundation. |

### The drawn interface and the apps

| | |
|---|---|
| `Sources/DriftboxShell` | What the app asks of a window (input, menus, file panels, a loop), the same on every platform. |
| `Sources/DriftboxWin32`, `Sources/DriftboxGTK` | That on Win32, and on GTK 4. |
| `Sources/DriftboxInterface` | The controls, drawn on the canvas in points over the scene: the transport, the song strip, the step grid, the knobs, and the rack, laid out and hit from one layout. |
| `Sources/DriftboxDesktop` | Driftbox on a desktop with a `ShellWindow`: menus, the scene, the controls over it, the pad, the rack. Windows and Linux run it. |
| `Sources/DriftboxTouch` | Driftbox on a touch screen: the same, and what each finger is. Android runs it, and iOS can. |
| `Sources/DriftboxApp` | The Mac app's logic and SwiftUI views, as a library so that it can be tested. |
| `Sources/Driftbox` | The Mac executable, which is nothing but `@main`. |
| `Sources/DriftboxAudioUnits` | The AUv3 app extension's executable and its view controller. `scripts/bundle-app.sh` makes the `.appex` around it inside the app. |
| `Sources/DriftboxWindows` | The Windows app: Windows' parts, chosen and handed to `DriftboxDesktop`. |
| `Sources/DriftboxAndroid`, `android/` | The Android app's native library, and its Java, manifest and resources. |
| `Sources/driftbox-linux`, `driftbox-linux-window` | The Linux desktop, and a standalone window used to qualify GTK and GLES. |
| `Sources/driftbox-play` | A song through the speakers on any platform, optionally with its scene in a window. |
| `Sources/driftbox-render` | A song to a WAV file. |

## The constrained targets

The four audio targets (`DriftboxDSP`, `DriftboxSeq`, `DriftboxEngine` and `DriftboxRack`) take
nothing from outside themselves: no Foundation, no platform, no dependencies. They do not
allocate, lock, or touch a class or an existential on the render path. That is what makes them
safe on a real-time thread, and what makes a render a function of the song and nothing else.

The compiler checks it, in two halves, because neither half is enough alone:

```bash
scripts/check-constrained.sh
```

1. They compile as **Embedded Swift** for a bare WebAssembly target. That rules out Foundation,
   reflection and the platform. It does *not* rule out existentials: Embedded Swift accepts
   `any P` as of 6.3, which was measured rather than assumed.
2. Every function on the render path is marked **`@_noAllocation`**, and an optimised build
   turns an allocation, an existential or a class instance inside one into an error.

The Embedded half needs a swift.org toolchain, since Xcode's ships no Embedded standard library.
The script finds `~/Library/Developer/Toolchains/swift-latest.xctoolchain`, or takes
`DRIFTBOX_EMBEDDED_SWIFTC`.

The one thing the DSP takes from outside is `exp` and `tanh` from the C library
(`Sources/DriftboxDSP/Math.swift`). See [Exactness](conformance.md#exactness).

Three things the compiler taught along the way, all of which are now rules:

- An array cannot be read from a function that promises not to allocate, so storage is pointers
  owned by a non-copyable type.
- Nor can a generic type be touched, so fixed arrays are written out.
- Such a function can only call what makes the same promise, across files as well as modules.
  That includes reading a `static let`, because it is initialised on first use, behind a lock.

Everything that makes sound exists in an offline form and a real-time form, and the second is
held to the first; [conformance.md](conformance.md#offline-forms-and-real-time-forms) says how.

## The ports

The ports are small on purpose, and nothing crosses them that is not the same on every platform.

- **A device is an ID and a name** (Core Audio's UID, Windows' endpoint ID, a PipeWire node's
  name), because that is what a choice of one is remembered by. A MIDI port is a name for the
  same reason.
- **A time is a `HostTime`**, the machine's monotonic clock, which is what each platform's MIDI
  stamps against.
- **There is no sample rate setting.** The engine runs at 48 kHz and the output converts.
- **There is no pretending.** A virtual MIDI source that a platform cannot publish (Windows
  cannot) is not offered: `offersVirtualSource` says so.

`MIDIQueue`, in `DriftboxHost`, holds stamped MIDI until it is due, for the platforms whose MIDI
sends at once whatever the stamp says (WinMM on Windows, and Android's for every device but USB).

## The render thread

The render thread crosses the one boundary where the constrained targets' rule has to be kept by
hand. A device renders a `RenderSource` (a C function and a context pointer) rather than a
protocol or a closure, so that a platform's audio callback calls into Driftbox without retaining,
releasing or dispatching through a witness table. `EngineHost` and `RackHost` each hand one out.

On every platform the sources are summed by `DriftboxHost`'s `Mixer`, through a table swapped
whole behind one atomic pointer; the old table is freed only once the render thread has finished
a buffer since. On the Mac the sum plays through one source node into the engine's mixer, beside
any Audio Units attached to the engine directly.

## Shared sessions

**What an app holds** is `DriftboxSession`'s `Session`: the groovebox without any platform in it.
It holds the song and the transport, the loop, the metronome and the count-in, editing and undo,
a MIDI clock followed and one sent, and what is remembered between launches. It also ships the
catalogue of songs.

- **The platform arrives through the ports:** `AudioRouting`, `MIDIInputPort` and
  `MIDIOutputPort`, given by the app. A session made without them is the whole of it and none of
  the hardware, which is how its tests make one.
- **Nothing in it keeps time.** The app calls `tick` from its own loop: on Windows and Linux the
  window's, on Android `Choreographer`'s.
- **Undo is its own.** Foundation's `UndoManager` is not there on Windows or Android, and every
  edit is a song before and a song after, so `UndoHistory` is a stack of those with their names.
- **What is remembered** goes through `SessionMemory`: `UserDefaults` everywhere but Android,
  under the Mac app's original keys so that its preferences carried over, and on Android
  `FileMemory`, a JSON file among the app's own, since `UserDefaults` there is the old
  Foundation's.
- **Something else can take the MIDI** that arrives, through `MIDIListener`: the rack, while it
  is in front.

`DriftboxRackSession`'s `RackSession` is the rack's counterpart: the patch, its edits and undo,
the keys and the controllers learnt onto it, samples, its song and transport, the catalogue of
patches, and the guided tours. It reaches audio, plug-ins and file reading through ports of its
own.

Every app is built the same way: it makes its platform's adapters and hands them to a `Session`
and a `RackSession`, then ticks both. On the Mac, `Studio` does it and SwiftUI draws. On Windows
and Linux, `DriftboxDesktop` does it and draws through a `ShellWindow`; on Android,
`DriftboxTouch` does it for a touch screen.

## The window

The window is a port as well. `DriftboxShell` says what the app asks of one, in terms that are
the same on every platform:

- **Input** as `ShellEvent`s: a pointer for a mouse, a finger and a pen alike, in points from the
  top left; keys known by what they type; scrolling.
- **A `MenuBar`** as data, whose commands arrive by id whether chosen or reached by their
  shortcut. A shortcut is written with `.primary`, which is Command on the Mac and Control
  elsewhere, so one menu reads ⌘S on the one and Ctrl+S on the other.
- **The file panels**, a loop to draw in, and `post`, for word from another thread.

The Mac has AppKit and SwiftUI for all of this and does not use it. `DriftboxWin32` answers it on
Windows (see [windows.md](windows.md#the-window)) and `DriftboxGTK` on Linux.

## Conventions

Swift 6.4, Swift Testing, `swift format` (configuration in `.swift-format`; CI lints with
`--strict`). macOS 26 and iOS 26 are the floors: the first with `InlineArray`, which needs the
runtime they ship and cannot be deployed back to an older one.

Tests run with `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6`, which makes a test run
check actor isolation as strictly as the app does. Without it the test runner is lenient, and a
closure made on the main actor but called from an audio or MIDI thread traps in the app while
every test passes.
