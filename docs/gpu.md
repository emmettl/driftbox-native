# The GPU layer, type and the canvas

The scenes, and everything drawn on Windows, Android and Linux, go through a small GPU layer with
a backend on each platform, a typesetter on each platform, and a 2D canvas on top of both. What
is drawn with them is in [visuals.md](visuals.md); how the targets fit together is in
[architecture.md](architecture.md).

## The layer

The GPU is a port, like audio and MIDI: `DriftboxGPU` says what may be asked of one, and a
backend answers it on each platform: Metal on the Mac (`DriftboxGPUMetal`), Direct3D 11 on
Windows (`DriftboxGPUD3D11`), and OpenGL ES 3.0 on Android and Linux (`DriftboxGPUGLES`).

What it offers is what all three do the same way, and nothing more: buffers, textures, pipelines
under three.js's three blends and a multiply, its depth tests with or without writes and its
culling, per-draw uniforms, and vertex attributes stepping per vertex or per instance.

- **No sized points**, since Direct3D cannot size one, so a sprite is an instanced quad everywhere.
- **No storage buffers**, since OpenGL ES 3.0 has none.
- **The conventions every backend keeps:** clip space y up with depth 0...1, a target's first row
  its top, and a triangle's front counter-clockwise as it appears there, which is three's.

Apple's `simd` exists only on Apple's platforms, so `DriftboxGPU` has a `Matrix4` of its own, with
the same memory as `simd_float4x4`.

### The contract

`GPUContractTests` holds a backend to those conventions (which way up a target reads back, depth
written and only tested, which faces are culled, the blends to the byte, instanced sprites,
textures, buffers written again) and runs against every backend the platform has.

- **Direct3D** runs it on WARP, Windows' software rasteriser, so the pixels are the same on every
  machine and CI needs no graphics card.
- **Metal** runs it on the Mac's own GPU.
- **OpenGL ES** runs it on Linux, on Mesa's software rasteriser, surfaceless, for WARP's reasons.
- **A phone** cannot run Swift Testing, so `scripts/android-app.sh gpu` runs the same checks, with
  the same programs, on the phone's own GPU.

A test that the platform's backend is among those tested stops a platform passing the contract
by testing nothing.

### OpenGL ES

OpenGL's framebuffers start at the bottom, where the layer's targets start at the top. So the
OpenGL ES backend draws every target upside down, turning each vertex shader's y over as it
compiles it: a target's first row in memory is then its top, read back in order, sampled from the
top left, with `gl_FragCoord` counting down from the top as it does in Metal and Direct3D.
Drawing upside down turns every triangle over too, so the backend calls the layer's front
clockwise. A window is the one thing that is not a target, and is turned over on the way to it.

OpenGL ES 3.0 has no BGRA texture, so a BGRA texture is stored as given and read through a
swizzle that swaps red and blue, and a target is swapped as it is read back. Its GLSL cannot bind
a uniform block or a sampler in the shader, so each is bound by name when the program links.

### Metal

Metal has one table of buffers where the other two have uniform blocks and vertex buffers apart.
The shaders read block `n` at `buffer(n)`, so the Metal backend binds vertex buffer slot `n` at
`buffer(16 + n)`. It writes buffers and textures again with a blit on its one queue, so a draw
already asked for reads what was there and the next reads what was written. That is what
Direct3D's `UpdateSubresource` does, and what writing their memory from the CPU would not.

## Shaders

The shaders are written once, in GLSL, the language the web's scenes were written in, so a scene
still reads like the one it came from. They live in `shaders/<Target>/<program>.vert` and
`.frag`.

```bash
node scripts/shaders.mjs           # make every backend's language from the GLSL
node scripts/shaders.mjs --check   # fail if what is checked in is stale
```

glslang compiles the GLSL to SPIR-V, and SPIRV-Cross writes that out as Metal, HLSL and GLSL ES.
Both come with the Vulkan SDK, which only whoever edits a shader needs. What comes out is checked
in as Swift, in each target's `Generated/ShaderPrograms.swift`: the programs in every language,
and a Swift struct for every uniform block, written from SPIRV-Cross's reflection member by
member at the offsets the shaders read.

Swift and std140 disagree in two places: a scalar after a `vec3`, and an array of anything smaller
than a `vec4`. A block that falls into either is refused by the generator with the reason, rather
than drawn from the wrong bytes. A test holds every generated struct to its block besides.

Without the SDK, `--check` compares each generated file's hashes, of its GLSL and of itself, which
is what CI does rather than download 330MB to check a few files. With it, `--check` makes
everything again and compares it whole.

## On screen

A `GPUSurface` is a window's swap chain: the frame's target, a resize, and a present that waits
for the display. A backend makes one from its own platform's kind of window; drawing into it and
showing it are the same everywhere. `Presenter` shows a finished frame in one, fitted or cropped.

- **On Windows** the surface is a flip-model swap chain, tested on a real one for a window that is
  never shown.
- **On the Mac** it is a `CAMetalLayer`'s drawables, not framebuffer-only so that a frame can be
  sampled and read back as Direct3D's can, tested on a layer in no window.
- **On Android** it is an EGL window surface.
- **On Linux** GTK owns the GL context and schedules the frame, and the surface copies each frame
  into GTK's framebuffer without owning or swapping it (`GTKSurface`).

## Type

Drawing text is mostly the same everywhere: packing glyphs into a texture, placing them through a
transform, colouring them. So that part lives on the GPU layer, in `DriftboxCanvas`, and only two
things are asked of a platform. `DriftboxText`'s `Typesetter` is asked for a font the way the
web's canvas asks, as families in order of preference with a weight and a size in pixels. It must
then:

- **set a line:** shaped, so kerned as the font says, and returned as glyphs placed on the
  baseline with the width `measureText` would give;
- **give one glyph's coverage:** grey, antialiased, and at a fraction of a pixel along.

`TypesetterTests` holds a typesetter to how type behaves rather than to one font's numbers: it
falls back through its families, scales exactly, kerns AV, measures trailing spaces, stands an I
on its baseline, and draws a heavier weight with more ink. Swift Testing does not run on a phone,
so `scripts/android-app.sh text` runs the same checks there, on a thread of Swift's own.

### Core Text, on the Mac

`DriftboxTextMac`'s `CoreTextTypesetter`. The Mac app's own interface is SwiftUI and does not use
it; the scenes on the GPU layer do, in `driftbox-play --window` and in the scene tests.

### DirectWrite, on Windows

`DriftboxTextWindows` answers it with DirectWrite. Its text layout does the shaping, drawn through
a text renderer written in Swift that collects the glyphs, and a glyph run analysis rasterises
each glyph. DirectWrite's headers are C++ only, so `CDirectWrite` declares the part of it that is
called, transcribed in vtable order. COM never changes that order, and a slot in the wrong place
fails the first test that reaches it.

### Android's text stack

`DriftboxTextAndroid` answers it with Android's own text stack, through the app's Java, since the
NDK can find a font but has nothing to shape or draw one with. `TextRunShaper` sets the line, with
Minikin and HarfBuzz underneath, and `Canvas.drawGlyphs` draws a glyph into an alpha bitmap. Both
need Android 12. A family is looked up in the names `fonts.xml` gives, which include the web's
usual ones as aliases: Arial and Helvetica are Roboto. Two details of drawing a glyph as it was
set:

- **Weight.** The font a shaped run hands back is the file and not how it was used. Roboto is
  variable, so its `wght` axis is set again to the weight Minikin gave it, and a face with nothing
  that heavy is emboldened again.
- **Threads.** Swift calls in from any thread. The render thread is attached to Java on its first
  call and let go of as it ends.

On a Fairphone 6, a line costs 35µs and 4µs a glyph when Minikin has laid its text out before,
and about 170µs when it has not; a glyph's coverage costs 90µs.

### Pango, on Linux

`DriftboxTextLinux`'s `PangoTypesetter`, through `CLinuxUI`. See [LINUX.md](LINUX.md).

## The canvas

`DriftboxCanvas` is the rest of drawing type, and of drawing in two dimensions: the part of
Canvas2D that Driftbox draws with, on the GPU layer. The drawn interface on Windows, Android and
Linux is drawn with it, and so is Graphic Lab's print.

- **What it keeps:** Canvas2D's state and its `save` and `restore`. That is a transform, a clip, a
  fill and a stroke, a line width, a blend (normal or multiply), a font and an alignment.
- **What it draws:** rectangles, ellipses, stroked lines, `fillText` with `measureText`, and the
  page drawn onto itself, moved, as `drawImage` of a canvas onto itself does.
- **How:** every mark is an instanced quad of one program, placed by its own transform.
  - Rectangles and ellipses are antialiased analytically, glyphs come from an atlas the
    typesetter fills, and a copy of the page comes from the other of two targets.
  - The clip is a rectangle each mark carries and the fragment shader honours, so the layer needs
    no scissor.
  - `GPUBlend.multiply` is there for it: what is there times the colour drawn.

`CanvasTests` holds it to what Canvas2D draws: coverage at a half-pixel edge, the transform, the
clip and `restore`, multiply, a round ellipse, a line's width, a page copied onto itself twice,
and type landing where it is aligned.
