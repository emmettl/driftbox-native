# Driftbox, native

A native port of [Driftbox](https://github.com/emmettl/driftbox) — a TR-808, a TR-909 and a pair
of TB-303s, synthesised from scratch — for the Mac first, then iOS. Swift throughout.

The web app is the reference implementation and is treated as finished. It is here as a pinned
submodule in `driftbox/`, and nothing in this repository changes it.

**Where this is:** phase 7 of [ROADMAP.md](ROADMAP.md), making the Mac app a proper Mac app. The
groovebox is there: a harness that holds Swift to the web engine's behaviour, and behind it a song
model, a codec that reads and writes the web app's documents to the byte, a sequencer that plans
every catalogue song exactly as the reference does, all 22 drum voices — as data, exactly, and as
sound, within -100dB of the browser's — and the 303 (looser where there are square waves, drive or
a resonant ladder, for reasons given below); a real-time engine hosted as an Audio Unit; an editor
for everything a song is; MIDI in and clock out; and all twenty-seven of the web's scenes in
Metal. Next after this is the rack.

## Layout

| | |
|---|---|
| `driftbox/` | The web repository, pinned. The reference for everything below. |
| `conformance/emit/` | Runs the reference TypeScript as it stands and writes fixtures from it. |
| `conformance/fixtures/` | What the Swift tests are held to. Checked in. |
| `Sources/DriftboxDSP` | Filters, oscillators, envelopes, noise. **Constrained.** |
| `Sources/DriftboxSeq` | What a song is and what it decides to play. **Constrained.** |
| `Sources/DriftboxEngine` | The instruments, mixer and effects behind one `render`. **Constrained.** |
| `Sources/DriftboxRack` | The modular rack: the patch compiler, the graph, the modules. **Constrained.** |
| `Sources/DriftboxDocument` | The song codec, migrations, shareable URLs, the catalogue. |
| `Sources/DriftboxHost` | The engine and rack hosts, the rings to and from the render thread, the ports every platform's audio and MIDI sits behind, and the mixer every platform's output renders through. |
| `Sources/DriftboxHostMac` | Core Audio and Core MIDI behind those ports, and Audio Units: the engine and the rack as units, and units hosted in the rack. The host on the Mac. |
| `Sources/DriftboxHostWindows` | WASAPI and WinMM behind those ports: the host on Windows. |
| `Sources/CWASAPI` | The Windows audio headers Swift's WinSDK module leaves out. Declarations only. |
| `Sources/DriftboxHostAndroid` | AAudio and native MIDI behind the same ports: the host on Android. |
| `Sources/CAAudio`, `Sources/CAMidi` | AAudio's and native MIDI's headers, which the Swift SDK's Android module leaves out. Declarations only. |
| `android/` | The Android app's Java, manifest and resources: so far a harness, and the MIDI devices Java can open. |
| `Sources/DriftboxAndroid` | The Android app's native library: what its Java calls, and the tests it runs on a phone. |
| `Sources/DriftboxSession` | What an app holds, on every platform: the song, the transport, editing and undo, the MIDI clock both ways, what is remembered, and the catalogue. |
| `Sources/DriftboxScenes` | The visuals: the analyser, the surface and geometry layers, the scenes. |
| `Sources/DriftboxGPU` | What the scenes ask of a GPU, as a protocol every backend answers the same way. |
| `Sources/DriftboxGPUD3D11` | That protocol on Direct3D 11: the GPU on Windows. |
| `Sources/DriftboxGPUMetal` | That protocol on Metal: the GPU on the Mac and iOS. |
| `Sources/DriftboxGPUGLES` | That protocol on OpenGL ES 3.0: the GPU on Android, and on Linux for CI. |
| `Sources/CGLES` | EGL's and OpenGL ES 3.0's headers. Declarations only. |
| `Sources/DriftboxShell` | What the app asks of a window — input, menus, file panels, a loop — the same on every platform. |
| `Sources/DriftboxWin32` | That on Windows: the Windows shell. |
| `Sources/DriftboxText` | What the app asks of a platform's type: a line set in a font, and a glyph's coverage. |
| `Sources/DriftboxTextWindows` | That on DirectWrite: type on Windows. |
| `Sources/DriftboxTextAndroid` | That on Android's own text stack, through the app's Java: type on Android. |
| `Sources/CDirectWrite` | The part of DirectWrite that is called, declared in C, since its own headers are C++. Declarations only. |
| `Sources/DriftboxCanvas` | A 2D canvas on the GPU layer: Canvas2D's shapes, state, type and blends, the same on every platform. |
| `shaders/` | The GLSL every shader is written in, once. `scripts/shaders.mjs` makes each backend's language from it. |
| `Sources/DriftboxInterface` | The controls, drawn on the canvas in points over the scene: the transport bar and the step grid, laid out and hit from one layout, on `Session`. |
| `Sources/DriftboxRackSession` | The rack as an app holds it, on every platform: the patch, its edits and undo, the keys, controllers, samples, song and transport, and the catalogue of patches; audio, plug-ins and file reading behind ports. |
| `Sources/DriftboxDesktop` | Driftbox on a desktop with a `ShellWindow`: menus, the scene, the controls over it, the pad, on `Session`. |
| `Sources/DriftboxTouch` | Driftbox on a touch screen: the scene, the controls over it, the pad, and what each finger is, on `Session`. Android's app uses it, and iOS's can. |
| `Sources/DriftboxWindows` | The Windows app: Windows' parts, chosen and handed to `DriftboxDesktop`. |
| `Sources/DriftboxApp` | The Mac app's logic and views, as a library so it can be tested. |
| `Sources/Driftbox` | The executable, which is nothing but `@main`. |

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

## Platforms

The Mac is the first platform, not the only one. What the rest of Driftbox asks of a platform is
written down once, in `DriftboxHost`, and each platform answers it in a target of its own:

```
the app            views, and the one place that picks a platform's adapters
adapters           DriftboxHostWindows: WASAPI, WinMM      DriftboxHostAndroid: AAudio, AMidi
                   DriftboxHostMac: AVAudioEngine, CoreMIDI, Audio Units
ports              DriftboxHost: AudioRouting, MIDIInputPort, MIDIOutputPort, HostTime, RenderSource
hosts              DriftboxHost: EngineHost, RackHost, the rings, the Mixer
constrained core   DSP, Seq, Engine, Rack
```

Dependencies point down and never across: nothing platform-neutral imports a platform, and no
adapter knows another exists. `Package.swift` says so too — `DriftboxHostWindows` depends on its
C headers only when building for Windows, and its sources compile to nothing anywhere else.

**The ports** are small on purpose, and nothing crosses them that is not the same on every
platform. A device is an ID and a name — CoreAudio's UID, Windows' endpoint ID — because that is
what a choice of one is remembered by. A MIDI port is a name for the same reason. A time is a
`HostTime`, the machine's monotonic clock, which is what each platform's MIDI stamps against. What
is *not* in them is as deliberate: no sample rate setting (the engine runs at 48 kHz and the
output converts, on both platforms), and no virtual MIDI source that a platform cannot publish
(Windows cannot, so `offersVirtualSource` says so rather than pretending).

**The render thread** crosses the one boundary where the constrained targets' rule has to be kept
by hand. A device renders a `RenderSource` — a C function and a context pointer — rather than a
protocol or a closure, so that a platform's audio callback calls into Driftbox without retaining,
releasing or dispatching through a witness table. `EngineHost` and `RackHost` each hand one out.
On every platform the sources are summed by `DriftboxHost`'s `Mixer`, through a table swapped
whole behind one atomic pointer, and the old table is freed only once the render thread has
finished a buffer since. On the Mac the sum plays through one source node into the engine's mixer,
beside any Audio Units attached to the engine directly.

**Where it stands.** `DriftboxHostWindows` is built on the ports and tested against them, and so
is `DriftboxHostAndroid`'s audio, played through a phone. `DriftboxHostMac` is too: `AudioRoute`
is the Mac's `AudioRouting`, `MIDIInput` and `MIDIOutput` its MIDI ports, and the clock is
`HostTime`'s. `Player` and `MacRack` still play their engine and rack as Audio Units in the route's
engine rather than as sources on it; moving the groovebox onto `Session` is what changes that, and
after it `driftbox-play` can be one program on every platform rather than branches.

**What an app holds** is `DriftboxSession`'s `Session`: the Mac app's `Player` without the Mac in it.
It holds the song and the transport, the loop, the metronome and the count-in, editing and undo, a
MIDI clock followed and one sent, and what is remembered between launches. It also ships the
catalogue of songs.
- **The platform arrives through the ports:** `AudioRouting`, `MIDIInputPort` and `MIDIOutputPort`,
  given by the app. A session made without them is the whole of it and none of the hardware, which
  is how its tests make one.
- **Nothing in it keeps time.** The app calls `tick` from its own loop, which on Windows is the
  window's.
- **Undo is its own.** Foundation's `UndoManager` is not there on Windows, and every edit is a song
  before and a song after, so `UndoHistory` is a stack of those with their names.
- **Settings persist under the Mac app's own keys,** so that its preferences come with it.

The Windows app is to be built on it. The Mac app still has its `Player`, which reads the catalogue
and the clock cursor from the session, until it moves onto `Session` too, on a Mac.

### The GPU

The scenes' GPU is a port of the same kind: `DriftboxGPU` says what they may ask of one, and a
backend answers it on each platform — Direct3D 11 on Windows, Metal on the Mac, OpenGL ES 3.0 on
Android.
What it offers is what all three do the same way, and nothing more: buffers, textures, pipelines
under three.js's three blends, its depth tests with or without writes and its culling, per-draw
uniforms, and vertex attributes stepping per vertex or per instance. There are no sized points, since Direct3D cannot size one, so a sprite is
an instanced quad everywhere; and no storage buffers, since OpenGL ES 3.0 has none. The
conventions every backend keeps: clip space y up with depth 0...1, a target's first row its top,
and a triangle's front counter-clockwise as it appears there, which is three's.

`GPUContractTests` holds a backend to those conventions — which way up a target reads back,
depth written and only tested, which faces are culled, the blends to the byte, instanced sprites,
textures, buffers written again — and runs against every backend the platform has. Direct3D runs it on WARP, Windows' software rasteriser,
so the pixels are the same on every machine and CI needs no graphics card; Metal runs it on the
Mac's own GPU; OpenGL ES runs it on Linux, on Mesa's software rasteriser, surfaceless, for WARP's
reasons. A phone cannot run Swift Testing from here, so `scripts/android-app.sh gpu` runs the same
checks, with the same programs, on the phone's own GPU. A test that the platform's backend is among
those tested stops a platform passing the contract by testing nothing.

OpenGL's framebuffers start at the bottom, where the layer's targets start at the top. So the
OpenGL ES backend draws every target upside down, turning each vertex shader's y over as it
compiles it: a target's first row in memory is then its top, read back in order, sampled from the
top left, with `gl_FragCoord` counting down from the top as it does in Metal and Direct3D. Drawing
upside down turns every triangle over too, so the backend calls the layer's front clockwise. A window
is the one thing that is not a target, and is turned over on the way to it. OpenGL ES 3.0 has no
BGRA texture, so a BGRA texture is stored as given and read through a swizzle that swaps red and
blue, and a target is swapped as it is read back; and its GLSL cannot bind a uniform block or a
sampler in the shader, so each is bound by name when the program links.

Metal has one table of buffers where the other two have uniform blocks and vertex buffers apart:
the shaders read block `n` at `buffer(n)`, so the Metal backend binds vertex buffer slot `n` at
`buffer(16 + n)`. It writes buffers and textures again with a blit on its one queue, so a draw
already asked for reads what was there and the next reads what was written — what Direct3D's
`UpdateSubresource` does, and what writing their memory from the CPU would not.

**The shaders are written once, in GLSL**, the language the web's scenes were written in, so a scene
still reads like the one it came from. They live in `shaders/<Target>/<program>.vert` and `.frag`.

```bash
node scripts/shaders.mjs           # make every backend's language from the GLSL
node scripts/shaders.mjs --check   # fail if what is checked in is stale
```

glslang compiles the GLSL to SPIR-V, and SPIRV-Cross writes that out as Metal, HLSL and GLSL ES.
Both come with the Vulkan SDK, which only whoever edits a shader needs. What comes out is checked
in as Swift, in each target's `Generated/ShaderPrograms.swift`: the programs in every language, and a
Swift struct for every uniform block, written from SPIRV-Cross's reflection member by member at the
offsets the shaders read. Swift and std140 disagree in two places — a scalar after a `vec3`, and an
array of anything smaller than a `vec4` — and a block that falls into either is refused by the
generator with the reason, rather than drawn from the wrong bytes. A test holds every generated
struct to its block besides.

Without the SDK, `--check` compares each generated file's hashes, of its GLSL and of itself, which
is what CI does rather than download 330MB to check a few files; with it, `--check` makes
everything again and compares it whole.

Apple's `simd` exists only on Apple's platforms, so `DriftboxGPU` has a `Matrix4` of its own, the
same memory as `simd_float4x4`.

**On screen**, a `GPUSurface` is a window's swap chain: the frame's target, a resize, and a present
that waits for the display. A backend makes one from its own platform's kind of window; drawing
into it and showing it are the same everywhere. `Presenter` shows a finished frame in one, fitted
or cropped. On Windows the surface is a flip-model swap chain, tested on a real one for a window
that is never shown. On the Mac it is a `CAMetalLayer`'s drawables, not framebuffer-only so that a
frame can be sampled and read back as Direct3D's can, tested on a layer in no window.

**The window itself** is a port as well. `DriftboxShell` says what the app asks of one, in terms that
are the same on every platform: input as `ShellEvent`s — a pointer for a mouse, a finger and a pen
alike, in points from the top left; keys known by what they type; scrolling — a `MenuBar` as data,
whose commands arrive by id whether chosen or reached by their shortcut; the file panels; a loop to
draw in; and `post`, for word from another thread. A shortcut is written with `.primary`, which is
Command on the Mac and Control elsewhere, so one menu reads ⌘S on the one and Ctrl+S on the other.
The Mac has AppKit and SwiftUI for all of this and needs none of it; it is for Windows and Android.

`DriftboxWin32` answers it. While a window is dragged or resized Windows runs a loop of its own and
the app's stops, so the window draws a frame from a timer and on every change of size until the
drag ends, and the picture follows the edge instead of freezing. Its loop is the only one on its
thread — Foundation's run loop, turned as well, took the window's key messages before its shortcuts
could, which is how Space came to play nothing — so work from other threads, such as an audio
device's change, comes through `post`, onto the window's own queue.

**Type is a port too, and a small one.** Drawing text is mostly the same everywhere: packing glyphs
into a texture, placing them through a transform, colouring them. So that part will live on the GPU
layer, where the Windows app's interface will draw, and only two things are asked of a platform.
`DriftboxText`'s `Typesetter` is asked for a font the way the web's canvas asks, as families in
order of preference with a weight and a size in pixels. It must then:
- set a line: shaped, so kerned as the font says, and returned as glyphs placed on the baseline
  with the width `measureText` would give;
- give one glyph's coverage: grey, antialiased, and at a fraction of a pixel along.

`DriftboxTextWindows` answers it with DirectWrite. Its text layout does the shaping, drawn through a
text renderer written in Swift that collects the glyphs, and a glyph run analysis rasterises each
glyph. DirectWrite's headers are C++ only, so `CDirectWrite` declares the part of it that is called,
transcribed in vtable order. COM never changes that order, and a slot in the wrong place fails the
first test that reaches it.

`DriftboxTextAndroid` answers it with Android's own text stack, through the app's Java, since the
NDK can find a font but has nothing to shape or draw one with. `TextRunShaper` sets the line, with
Minikin and HarfBuzz underneath, and `Canvas.drawGlyphs` draws a glyph into an alpha bitmap. Both
need Android 12. A family is looked up in the names `fonts.xml` gives, which include the web's
usual ones as aliases: Arial and Helvetica are Roboto. Two details of drawing a glyph as it was set:
- **Weight.** The font a shaped run hands back is the file and not how it was used. Roboto is
  variable, so its `wght` axis is set again to the weight Minikin gave it, and a face with nothing
  that heavy is emboldened again.
- **Threads.** Swift calls in from any thread. The render thread is attached to Java on its first
  call and let go of as it ends.

On a Fairphone 6, a line costs 35µs and 4µs a glyph when Minikin has laid its text out before,
and about 170µs when it has not; a glyph's coverage costs 90µs.

`TypesetterTests` holds a typesetter to how type behaves rather than to one font's numbers: it falls
back through its families, scales exactly, kerns AV, measures trailing spaces, stands an I on its
baseline, and draws a heavier weight with more ink. Swift Testing does not run on a phone, so
`scripts/android-app.sh text` runs the same checks there, on a thread of Swift's own.

`DriftboxCanvas` is the rest of drawing type, and of drawing in two dimensions: the part of Canvas2D
that Driftbox draws with, on the GPU layer.
- **What it keeps:** Canvas2D's state and its `save` and `restore`. That is a transform, a clip, a
  fill and a stroke, a line width, a blend (normal or multiply), a font and an alignment.
- **What it draws:** rectangles, ellipses, stroked lines, `fillText` with `measureText`, and the page
  drawn onto itself, moved, as `drawImage` of a canvas onto itself does.
- **How:** every mark is an instanced quad of one program, placed by its own transform.
  - Rectangles and ellipses are antialiased analytically, glyphs come from an atlas the typesetter
    fills, and a copy of the page comes from the other of two targets.
  - The clip is a rectangle each mark carries and the fragment shader honours, so the layer needs no
    scissor.
  - The layer gained `GPUBlend.multiply` for it: what is there times the colour drawn.

`CanvasTests` holds it to what Canvas2D draws: coverage at a half-pixel edge, the transform, the
clip and `restore`, multiply, a round ellipse, a line's width, a page copied onto itself twice, and
type landing where it is aligned.

**The scenes move across one at a time.** `GPUScene` is a scene on the layer, and Pulse is the
first: `PulseScene`, its shader the Metal one's GLSL line for line, held on WARP to what the Metal
one's test holds it to. On the Mac, where both can be drawn, it is held to the Metal `Pulse` itself,
pixel for pixel at five moments, within two in a channel.

The web's nine material studies came next, since each is one fragment shader and sometimes a
layer of instanced cards: Orrery, Switchback, Daydream, Small Hours, Paper Cities, Weave, Frost,
Hothouse and Night Bus. `GPUSurfaceScene` keeps their clocks, bands, touch and hits as the Metal
`SurfaceScene` does, and their shaders are the Metal ones' MSL back in GLSL over a shared
`surface.glsl`. Frost's crystals and Hothouse's leaves are cards, each placed by a matrix that steps
per instance.

Then the web's seventeen three.js scenes, on `GPUGeometryScene`: Wireframe, Sunset, Web, Saturn,
Lifeforms, Cubik, Stillwater, Cycles, Clouds, Longhand, Defcon, Dancers, Convoy, Machine, Jumpman,
Trench and Graphic Lab. So every scene is on the layer.
- **Camera and geometry.** The camera, the model matrices and the shapes they build (`Space.swift`)
  now use `Matrix4` and the standard library's vectors rather than Apple's `simd`. The Metal scenes
  reach the same code through a small bridge, so there is one copy of the arithmetic.
- **Sprites.** A point with a size, which Direct3D cannot draw, is an instanced quad. `sprite.glsl`
  sizes it in pixels against the viewport the base binds, and gives the fragment Metal's
  `point_coord`.
- **Per-point data.** Buffers the Metal shaders read by vertex id became vertex attributes. Small
  tables became uniform arrays.
- **Graphic Lab prints on `DriftboxCanvas`.** Its three editions draw on the canvas with the
  platform's typesetter, and the page is laid over the frame, as the web hands its canvas to WebGL.
  A scene is made with the platform's `Typesetter` for this: DirectWrite on Windows, Android's own
  text stack on Android. The Mac gives a `NoTypesetter`, which sets nothing, until it has a Core
  Text typesetter, which is why the Mac's comparison with the Metal scenes leaves Graphic Lab out
  for now.

Every scene on the layer plays the same six seconds as the Metal scenes' own test: kicks, hats,
and a finger circling through the middle two seconds. On WARP each is held to drawing something
that is not black and to moving. On the Mac each is held to its Metal scene frame by frame. With
`DRIFTBOX_SCENE_SHOTS` set, the test writes each scene's frames out to look at.

`GPUScenes` finds a song's scene by its `visual`, falling back to Pulse for one not yet across.
They are on screen:

```bash
driftbox-play conformance/fixtures/documents/saturn.song.json --window
```

The song plays through WASAPI on Windows, with its scene drawn through Direct3D. On the Mac it
plays through the engine's Audio Unit, with Pulse drawn through Metal. Either way a frame is drawn
once per refresh, from the events the engine reports playing and the mix it has made. On Windows
the window is the shell's:

- File ▸ Open… (Ctrl+O) opens another song, and its scene with it.
- Space plays and stops; Ctrl+Enter goes back to the start.
- View has the next and previous scene (Ctrl+Right, Ctrl+Left) and each scene by name.
- The whole window is a pad for the performance filter, as vibes mode is on the Mac, and the
  scene feels the finger.

With `DRIFTBOX_SCENE_SHOTS` set to a directory, as for the scene tests, each second's frame is
written there as it was presented: a BMP on Windows, a PNG on the Mac.

### Windows

Swift 6.4 from swift.org, and the Visual Studio Build Tools with the C++ compiler and a Windows
SDK. Build in a shell that has run `vcvars64.bat`, with `SDKROOT` pointing at the toolchain's
`Windows.sdk`.

```bash
swift build -c release --build-tests --build-system native -Xswiftc -enable-testing
swift test -c release --skip-build --build-system native
swift build -c release --product driftbox-play
swift build -c release --product DriftboxWindows
```

In release, because a debug build does not link there yet: the specialisations `@_noAllocation`
makes even at `-Onone` collide with the same ones `swiftSwiftOnoneSupport.dll` exports.

Audio is WASAPI in shared mode, event driven, float stereo at 48 kHz converted to the device's
format by Windows. Everything WASAPI is made, used and released on the stream's own thread at
Pro Audio priority, so the interface's thread keeps whichever COM apartment it needs. The route
follows devices through `IMMNotificationClient` — a COM object built by hand in Swift, as nothing
builds one — and a stream whose device goes away ends and asks to be replaced.

MIDI is WinMM, which sends at once and says nothing when devices change. So clock out goes through
a scheduler of its own that holds each message to its stamp on a high-resolution timer, to within
a millisecond, and devices are read again every two seconds and known by name. A clock for another
program on the same machine goes through a loopback port made in Windows MIDI Services.

**The app** is `DriftboxWindows`: a window with the song's scene filling it, the controls over it
— the transport bar, the song as a strip of sections to play from, the step grid and its
patterns, and the selected voice's knobs or the song's effects — the rest of it the performance filter's
pad, and menus for the rest. Tab hides the controls, to perform. The keyboard is an instrument,
as on the Mac: the number row strikes the drums, the home row plays 303 A, `z` and `x` its octave.
- **File:** New, Open…, the catalogue, Save and Save As… as `.driftbox`.
- **Edit:** Undo and Redo, named for the edit.
- **Transport:** play and stop, sections, the loop, the metronome and the count-in.
- **View:** the controls shown or hidden, and the song's scene or any other.
- **Audio and MIDI:** the output device, the MIDI inputs heard, and the MIDI clock followed or sent,
  and where. Settings are menu items the menu ticks as it opens.

Closing, opening or starting afresh over unsaved work asks first, in Windows' own words. Its
executable only chooses Windows' parts — WASAPI, WinMM, a Win32 window, Direct3D, DirectWrite — and
hands them to `DriftboxDesktop`, the app every platform with a `ShellWindow` runs, on `Session`.
`DesktopTests` hold that app to its menus, commands, title, care over unsaved work and frames, with
a stand-in window, on WARP.

**Shipping it.** The program carries Driftbox's icon, `windows/Driftbox.res`, which
`scripts/windows-icon.mjs` draws from the web app's own icon in a Chromium and compiles with the
SDK's `rc`: the four-pad picture at 16 to 32 pixels, the full one from 48 up. It opens a song it is
handed, as Explorer hands one over, and `DriftboxWindows.exe --register` makes `.driftbox` files
open in it and show its icon, for the current user, as an installer would; `--unregister` gives
them back. After a release build,

```bash
node scripts/windows-package.mjs
```

makes `dist/Driftbox`, which runs on a machine with no Swift on it, and a zip of it: the program,
the catalogue's resource bundle, and the Swift and Visual C++ runtime DLLs it loads, found by
reading their import tables — 18 of them, about 70MB, 26MB zipped.

### Android

The engine plays through a phone, and times itself there. It is built with the swift.org toolchain
for Windows and swift.org's Swift SDK for Android, the same version, with the NDK and adb beside
them:

```bash
scripts/android-play.sh                    # acid through the phone's speaker, for twenty seconds
scripts/android-play.sh song.json --seconds 60
scripts/android-bench.sh                   # --bench, once on each kind of core the phone has
```

Each builds `driftbox-play` for arm64 Android with `android-build.sh` and pushes it to
`/data/local/tmp`. There is no app and no install: Android runs a plain executable. It is linked
statically. swift.org's SDK rather than the Android platform the Windows installer brings, whose
standard library has no SIMD types and whose arm64 runtime cannot link Foundation; the build sets
the SDK up the first time, as its own script would, and `android-env.sh` says how.

Audio is AAudio: low-latency mode, exclusive if the device will give it, float stereo at 48 kHz.
The buffer starts at one burst and grows a burst at a time if the stream underruns. AAudio makes
the render thread; Driftbox keeps it to the big cores, since left to the scheduler it underran a
hundred times a second, and reports each callback's work to a performance hint session. A stream
whose device goes away ends and asks to be replaced, as on Windows. There is one device, the
system's, until the app can list them: that is Java's `AudioManager`.

MIDI is Android's native MIDI, which needs Android 10, so Driftbox builds for API 29. It can play
through a device but not find or open one: that is Java's `MidiManager`. So the app opens every
device and hands each to `AMidiDevices`, and `AMidiInput` and `AMidiOutput` open their ports from
there. Input is read by a thread that asks every port in turn, since there is no callback, and a
`MIDIByteStream` per port makes Android's packets back into messages: running status, clock in
the middle of a note, system exclusive skipped. Output is stamped, and what a stamp means is the
device's business: Android's USB driver holds a message until then, by its source, but a device
that is another app is handed it at once. So for every device but USB, `AMidiOutput` holds each
message in a scheduler of its own until it is due, and sends it stamped, as WinMM's scheduler
does on Windows; the two share `MIDIQueue` in `DriftboxHost`, and each waits in its own way.

The app is built without Gradle, by the SDK's own tools. Opened, it plays a song from the
catalogue with the scene the song names drawn from it over the whole screen, and the screen is
the performance filter's pad, as the window is on Windows; two fingers tapped step on to the next
scene. A scene is drawn at no more than two pixels to a point, a Mac's Retina display's, and
scaled up to the screen: on a Fairphone 6, which has three, every scene but Frost then keeps the
display's 120 frames a second, and Frost 98. Graphic Lab, which sets its type there with Android's
own text stack, takes 5.6ms a frame drawn, and more over its first frames at a size, while the
glyphs it sets go into its atlas. Given a test's name, the app runs that instead and says what
happened.

```bash
scripts/android-app.sh                  # build and install; open it for Pulse, playing acid
adb shell am start -n app.driftbox/.Main --es song smallhours --es scene hothouse
scripts/android-app.sh midi-loopback    # test the MIDI ports against the app's own loopback
scripts/android-app.sh gpu              # or the GPU contract on the phone's GPU
scripts/android-app.sh scenes           # or every scene drawn, checked and timed there
scripts/android-app.sh text             # or the typesetter, held to what every platform's is
```

The app is `Session` and the controls on a touch screen: `DriftboxTouch`'s `Touchscreen`, which is
`Desktop`'s counterpart for a screen with no window to ask things of, and which iOS can use as it
is. It draws the scene at no more than two pixels to a point, lays the controls over it at every
pixel, and decides what each finger is: the controls' if it lands on them, the pad's if it is the
first anywhere else, and a second finger tapped steps on to the next scene. Everything but the
audio is on Java's main thread, as a desktop's is on its window's: Java's `Choreographer` asks for
each frame and hands over each finger between them, and a window is let go of before Java's
`surfaceDestroyed` returns, as Android wants.

The session finds its songs as files, where the app unpacks them from its package, rather than
through `Bundle`: on Android that, `String(format:)` and `UserDefaults` are the old Foundation, and
it brings 48MB of internationalisation with it. The build tells the compiler not to link the old
Foundation at all, so anything that reaches for it fails to link rather than growing the package;
it is 16MB.

Out of view, or with the screen off, the song plays on and nothing is drawn: a media
playback service, with a notification to stop it from, keeps the process on the big cores, which
Android otherwise takes away from an app out of view. There the render thread costs half as much
again as in view, with no drawing to keep the cores awake, so the stream's buffer goes to sixteen
bursts at once, 32ms, and back to one in view. On a Fairphone 6, twenty seconds with the screen
off underran once, as it went off. A call, or another app's playing, pauses it, as media does.

It needs a JDK and the SDK's build-tools and a platform beside the NDK. Driftbox Loopback is a
MIDI device the app publishes that sends back what it is sent, so the ports are tested with
nothing plugged in, as on Windows. Notes and clock come back whole and in order, stamps exact. A
clock sent ahead goes out when it is due: a beat of it, tick by tick, 0.1 to 2ms after each tick
was due, and a flush drops what has not gone. Without the scheduler it came back a tenth of a
second early, the moment it was sent, and a flush dropped nothing.

## Conformance

```bash
node conformance/emit/emit.mjs          # rewrite the checked-in fixtures
node conformance/emit/emit.mjs --full   # also whole-song plans, into conformance/generated
node conformance/emit/emit-audio.mjs    # everything rendered in Chromium, into conformance/generated
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
| Edits | every transform in `pattern.ts`, applied by the reference to a catalogue song: 28 results | exactly |
| MIDI clock | a synthetic clock stream — jitter, a tempo change, a lost tick, stop, position, continue, a stall — through the reference's follower: what each of 464 messages made of it | exactly |
| Voices | what each of the 22 voices *describes* — its `VoiceSpec` — over nine panels and both velocities | exactly |
| Rack panels | every module's size; every factory and song patch's placements, jacks and drop targets; every cable's sag, seed, period, swing through two seconds both ways, and curve | exactly; the curve to the tenth it is written to |
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
| every voice struck between sample frames, at four times | as on a frame; the 909's cymbals -71 to -83dB |
| **whole mixes**: a window of eight catalogue songs | four at **-80 to -98dB**; four in level to 0.3dB, differing in a few stretches |
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
- **The reference started every oscillator at the wrong pitch, and no longer does.** A hit almost
  never starts on the first frame of a render quantum, and when it does not, Chromium — for the
  rest of that quantum — reads the oscillator's pitch from the *start of the quantum* instead of
  from where the oscillator started. The reference only scheduled a pitch, so what got read was
  the node's default: a hit 36 frames into a quantum played 36 frames of 440Hz, and the 909's
  cymbals began at the wrong speed. Measured on a bare sine at six start times, and exact; it is
  what the reference's notes had recorded, unexplained, as a closed hat's peak moving between 0.67
  and 3.97 "purely with where the hit falls inside a quantum". Found here, fixed there in
  driftbox#299 by setting the node's value as well. What is left is small: a pitch *envelope* is
  still read early for that one quantum, so a kick's drop arrives up to 2.6ms ahead. The engine
  does not do that either — it differs on every hit, and no two plays agree — and
  `emulatesBrowserSourceStart` turns it on for the comparisons.
- **Two single-precision details in how noise is read.** An oscillator starts at the top of its
  cycle on its first frame however late that frame is, where a buffer starts a fraction of a frame
  in. And a buffer's start offset goes through single precision before it is rounded to a frame:
  one kick in one song has an offset of 48374.4995 frames, which is 48374.502 as a float, rounds
  the other way, and came out with its click inverted.
- **Four whole mixes are not understood yet.** Four of eight songs match the reference whole at
  -80 to -98dB — every voice, both 303s, the sends, the compressor, the idle pad. The other four
  agree in level to 0.3dB throughout and differ in a few tenths of a second each. Bisected in the
  browser: give a song a voice that is both panned and sending to the delay, and the *reference's
  own* render of the 303 changes, before that voice has played a note, for the length of one bass
  note after the first thing scheduled from a suspend — and then goes back. This renderer gives the
  same 303 either way. It is a channel-count effect inside Chromium's delay loop, and it is not
  stable there either: those four are the songs on which an x64 and an arm64 Chrome disagree with
  *each other* most, by -30 to -37dB, where they agree on the other four to -56 to -81dB. The test
  holds the four to level and coverage until it is pinned down.
- **An idle filter is not an absent one.** The performance pad is a low-pass into a high-pass,
  both "wide open" when nobody is touching it, and the reference calls that a true bypass. Sample
  for sample its output differs from its input by nearly the whole signal: a 20Hz high-pass turns
  the phase of the bass, and a 20kHz low-pass shaves the top. Nobody hears it, and every mix the
  reference has ever rendered went through it — so `Kaoss` is in the chain here too, idle, and
  matches an arm64 Chrome at -141dB. (An x64 Chrome differs from the arm64 one by -76dB on the same
  idle pad: a high-pass at 20Hz has its poles almost on top of each other, and the two builds do
  that arithmetic differently. So -76dB is about as closely as *any* whole mix can be held to the
  reference across processors.)
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

### Offline forms and real-time forms

Everything that makes sound exists twice, on purpose. The **offline form** is where a thing is
understood: it allocates what it likes, reads like the reference, and is held to the browser. The
**real-time form** is where it is played: fixed storage, no allocation, no locks, no classes, every
function on the render path marked `@_noAllocation` — and it is held to the offline form, *to the
bit* where the arithmetic allows, so that nothing shown against the browser has to be shown again.

The real-time forms, held to their offline ones: `VoicePool` (the drum voices; **to the bit**),
`RealtimeBassline` (the 303; **to the bit**, on catalogue lines), `PartitionedConvolver` (the
reverb, with no latency; within single precision) and `SongEngine`, which plays a `CompiledSong` —
every hit and note worked out ahead of time on a thread that may allocate — through all of them
and the master chain, with a transport that loops: within -90dB of `SongRenderer` on four songs,
and the same whatever block size the host asks for. `EngineHost` puts a lock-free command ring in
front of it, and `DriftboxAudioUnit` makes that an `AUAudioUnit`, which `driftbox-play` hosts in
an `AVAudioEngine` and plays through the speakers.

`VoicePool` was the first: `VoiceRenderer` for a render thread. A hit is turned into a
`FixedVoiceSpec` — plain bytes, small enough for a ring — on a thread that may allocate, and
started and rendered on one that may not. All 22 voices, struck on and between frames, rendered in
blocks of 97 frames, match `VoiceRenderer` exactly; so does an open hat choked by a closed one.

Three things the compiler taught along the way, all of which are rules now: an array cannot be
read from a function that promises not to allocate, so storage is pointers owned by a
non-copyable type; nor can a generic type be touched, so fixed arrays are written out; and such a
function can only call what makes the same promise, across files as well as modules — which
includes reading a `static let`, because that is initialised on first use, behind a lock.

### The app

```bash
scripts/bundle-app.sh && open .build-release/Driftbox.app
```

The Mac app: the catalogue as a library, a transport, the step and 303 grids of the pattern the
transport is in, live and editable, the voice and effects panels, the pad, open, save and export,
MIDI in from the sources chosen in Settings and clock out, and the visuals — in a pane, and in a
window of their own (⌘2) that goes full screen on a named display from View ▸ Visuals Full Screen
On. One renderer draws each frame once and every view shows it, so the pane previews exactly what
the window is showing. The song and the visuals window come back at the next launch. A SwiftPM executable rather than an Xcode project for
now, which is why it announces itself to the system by hand on launch, and why a script has to
wrap it into a bundle: `swift run Driftbox` also works, but the catalogue lives in a resource
bundle that `Bundle.module` looks for beside the executable and in `Contents/Resources`, and the
script puts a copy in both.

### Visuals

`DriftboxScenes` is phase 6: a `Scene` protocol that keeps the web scenes' ids and accent
colours, so a song's `visual` hint resolves here too, and draws whatever it likes; a renderer
over one shader library compiled at launch; the fallback scene, driven by the engine's events
ring, the block peaks and the pad; and the web's nine *surface* scenes — Orrery, Switchback,
Daydream, Small Hours, Paper Cities, Weave, Frost, Hothouse and Night Bus — which are each one
fragment shader over the screen (two of them with a layer of instanced cards on top), fed the
same handful of numbers. Their GLSL carries to Metal almost line for line, under the web's own
uniform names, so those eight look exactly as they do there.

What they are fed is what the web feeds them. `Analyser` is Web Audio's `AnalyserNode` as the
web engine configures it — 2048 frames, Blackman window, 0.75 smoothing, -100 to -30 dB as
bytes — over a mono tap of the mix the host keeps for it, and then the web's `readBands`: eight
bands of constant ratio, three for bass, three for mids, two for highs. The score position
comes straight from the engine's atomics at the display's rate, smooth between steps, which is
one better than the web's.

The three.js scenes go over a geometry layer instead — `Camera`, three's projection and view
matrices with Metal's depth range, and `GeometryScene`, which owns buffers and pipelines under
three's blend modes — with each scene's vertex and fragment shaders carried over as the
surfaces' are. Wireframe, Sunset and Web are the first three; between them they
need a camera that looks and unprojects, model matrices, plane geometry and indexed draws.

A scene cannot be looked at from a test, but it can be drawn into a texture and read back:
every scene draws something that is not black and moves, and with `DRIFTBOX_SCENE_SHOTS` set
to a directory the test writes each one there as PNGs at three moments — which is how the
ports were checked by eye.

### Playing

```bash
swift run -c release driftbox-play conformance/fixtures/documents/acid.song.json --start-bar 8
```

The engine as an Audio Unit in an `AVAudioEngine`, through the speakers, printing what reaches
the output once a second. `--bench` runs the same engine with no device, as fast as it goes:
**3.3% of real time** on this machine, of which the reverb — now in two stages, the tail in
partitions eight blocks long — is about a third. Live, the render callback reports a fifth of
the audio's time on its own clock, and the difference is the platform, not the code: `--bench`
also runs the same calls paced as a device paces them, one every 10.7ms with a sleep between,
and they cost **16%** that way — five times the loop — because a core woken every ten
milliseconds does its first millisecond of work cold and slow. That is the number to budget
for, and it is fine.

On Windows the same command plays through WASAPI instead, and says which device and how far behind
the speakers are: 10ms on a laptop's own. The render call costs **8 to 13%** of the audio's time
there, its longest 2.8ms of a 10ms period — measured by wall time on the performance counter,
since Windows keeps a thread's own time only to its 15.6ms scheduler tick.

On a phone, a Fairphone 6 with a Snapdragon 7s Gen 3, `--bench` costs **13 to 16%** of real time
on a big core across the catalogue. That is four and a half times the Mac. On a little core it
costs **69%**, so a render thread must never land on one. Paced, the big core costs **67%**, its
longest call 9.7ms of a 10.7ms period. That number is the phone, not the code: with the rest of
the cluster kept busy, the same paced run costs **17.7%** and its longest call 2.5ms. It is not the
clock, either, though that was the first guess. Played through AAudio, in 2ms bursts, the render
costs about **60%** of each burst whether a performance hint holds the cluster at 2.2 GHz or lets
it fall to 0.6; with the other big cores kept busy it costs **15 to 18%**. What a callback pays
for is its core waking cold from idle. It is still in time: the heaviest song played for thirty
seconds without an underrun, its longest call 3.4ms, the speaker 4.8ms behind the render.

### Listening

```bash
swift run -c release driftbox-render conformance/fixtures/documents/smallhours.song.json smallhours.wav
swift run -c release driftbox-render song.json out.wav --start 15.2 --duration 8 --rate 48000
```

A song document in, a 32-bit float WAV out, at about thirty times real time. This is the native
render as the engine means it — without the browser's faults switched on.

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
macOS 26 and iOS 26 are the floors: the first with `InlineArray`, which needs the runtime
they ship and cannot be deployed back to an older one.

## Licence

[MIT](LICENSE), as the web app is. Use it, embed it, sell what you build with it: the engine is
meant to be picked up, and that is the licence that gets least in the way of doing so.
