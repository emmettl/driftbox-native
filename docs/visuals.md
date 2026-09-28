# Visuals

`DriftboxScenes` holds the visuals: all twenty-seven of the web's scenes, twice. The Mac app draws
them in Metal directly; every other platform, and `driftbox-play --window` on the Mac, draws them
through the GPU layer described in [gpu.md](gpu.md). Both are fed the same way and held to each
other.

## What a scene is fed

A `Scene` keeps the web scenes' ids and accent colours, so a song's `visual` hint resolves here
too, and draws whatever it likes from the same handful of numbers the web gives it.

- **The analyser.** `Analyser` is Web Audio's `AnalyserNode` as the web engine configures it:
  2048 frames, Blackman window, 0.75 smoothing, -100 to -30 dB as bytes, over a mono tap of the
  mix the host keeps for it. Then the web's `readBands`: eight bands of constant ratio, three for
  bass, three for mids, two for highs.
- **The score position** comes straight from the engine's atomics at the display's rate, smooth
  between steps, which is one better than the web's.
- **Events and the pad.** What the engine reports playing, the block peaks, and the performance
  pad, which a scene feels.

## The Metal scenes, on the Mac

A renderer over one shader library compiled at launch draws each frame once, and every view shows
it, so the pane in the Mac app's main window previews exactly what the visuals window is showing.

- **Pulse** is the fallback, for a song whose `visual` names nothing known.
- **The nine surface scenes** (Orrery, Switchback, Daydream, Small Hours, Paper Cities, Weave,
  Frost, Hothouse and Night Bus) are each one fragment shader over the screen, two of them with a
  layer of instanced cards on top. Their GLSL carries to Metal almost line for line, under the
  web's own uniform names.
- **The seventeen three.js scenes** (Wireframe, Sunset, Web, Saturn, Lifeforms, Cubik, Stillwater,
  Cycles, Clouds, Longhand, Defcon, Dancers, Convoy, Machine, Jumpman, Trench and Graphic Lab) go
  over a geometry layer instead: `Camera`, three's projection and view matrices with Metal's depth
  range, and `GeometryScene`, which owns buffers and pipelines under three's blend modes. Each
  scene's vertex and fragment shaders are carried over as the surfaces' are.

## The scenes on the GPU layer

`GPUScene` is a scene on the layer, and every scene has one.

- **Pulse** is `PulseScene`, its shader the Metal one's GLSL line for line.
- **The surface scenes** are on `GPUSurfaceScene`, which keeps their clocks, bands, touch and hits
  as the Metal `SurfaceScene` does. Their shaders are the Metal ones' MSL back in GLSL over a
  shared `surface.glsl`. Frost's crystals and Hothouse's leaves are cards, each placed by a matrix
  that steps per instance.
- **The three.js scenes** are on `GPUGeometryScene`.
  - *Camera and geometry.* The camera, the model matrices and the shapes they build
    (`Space.swift`) use `Matrix4` and the standard library's vectors rather than Apple's `simd`.
    The Metal scenes reach the same code through a small bridge, so there is one copy of the
    arithmetic.
  - *Sprites.* A point with a size, which Direct3D cannot draw, is an instanced quad.
    `sprite.glsl` sizes it in pixels against the viewport the base binds, and gives the fragment
    Metal's `point_coord`.
  - *Per-point data.* Buffers the Metal shaders read by vertex id are vertex attributes. Small
    tables are uniform arrays.
  - *Graphic Lab prints on `DriftboxCanvas`.* Its three editions draw on the canvas with the
    platform's typesetter, and the page is laid over the frame, as the web hands its canvas to
    WebGL. A scene is made with the platform's `Typesetter` for this.

`GPUScenes` finds a song's scene by its `visual`, falling back to Pulse.

## Testing a scene

A scene cannot be looked at from a test, but it can be drawn into a texture and read back. Every
scene plays the same six seconds in its tests: kicks, hats, and a finger circling through the
middle two seconds.

- **Everywhere**, each scene is held to drawing something that is not black, and to moving. On
  Windows that runs on WARP.
- **On the Mac**, where both can be drawn, each scene on the GPU layer is held to its Metal scene
  frame by frame. Pulse matches pixel for pixel at five moments, within two in a channel. Graphic
  Lab's type is set by Core Graphics in the Metal scene and from Core Text's glyph coverage on the
  canvas, which lands a glyph on a whole pixel, so it is compared as eight-pixel squares see it.
- **On a phone**, `scripts/android-app.sh scenes` draws, checks and times every scene.

With `DRIFTBOX_SCENE_SHOTS` set to a directory, the tests write each scene's frames there to look
at, at three moments: the Metal scenes' test as PNGs, the GPU layer's as BMPs. That is how the
ports were checked by eye.

## Seeing one

```bash
swift run -c release driftbox-play conformance/fixtures/documents/saturn.song.json --window
```

The song plays through the platform's audio, and its scene is drawn through the GPU layer in a
window: Metal with Core Text on the Mac, Direct3D with DirectWrite on Windows. A frame is drawn
once per refresh, from the events the engine reports playing and the mix it has made. With
`DRIFTBOX_SCENE_SHOTS` set, each second's frame is written there as it was presented.

On Windows the window is the shell's:

- File ▸ Open… (Ctrl+O) opens another song, and its scene with it.
- Space plays and stops; Ctrl+Enter goes back to the start.
- View has the next and previous scene (Ctrl+Right, Ctrl+Left) and each scene by name.
- The whole window is a pad for the performance filter, as vibes mode is on the Mac, and the
  scene feels the finger.

In the apps themselves, the visuals can go to a window of their own and full screen on a display
chosen by name, for a projector: ⌘2 and View ▸ Visuals Full Screen On on the Mac, Ctrl+2 and the
View menu on Windows.
