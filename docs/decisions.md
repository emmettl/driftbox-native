# Decisions

Why the port is built the way it is. Each entry is a choice that still holds, and the reason for
it. What was built, and when, is in the git history and [the roadmap](../ROADMAP.md).

## The reference

- **The web app is a fixed reference.** It lives in `driftbox/`, pinned, and nothing here changes
  it. That is what makes a second engine affordable: the tests can say Swift has fallen behind,
  and what it is behind has stopped moving. A bug found in the reference is fixed there, and here
  at the same time.
- **Sound matches by measurement where the Web Audio specification gives formulas:** biquads,
  parameter ramps, the panner and delays. The compressor and the 303's oscillator tables have no
  specification, so they follow Chromium's implementation and are judged by ear as well.
- **Quirks of the reference are copied when they change the result.** For example, the seeded
  random generator's FNV hash multiplies in doubles, which rounds past 2^53. A true 32-bit multiply
  would give a different noise, LFO and S&H melody from the same patch.
- **Visuals carry the intent, not the pixels.** A scene keeps its id and what it is about, so a
  song's `visual` hint means the same on every platform. The drawing is free to go past what a
  browser can do. Scenes are judged by eye.

## The engine

- **The audio lives in constrained targets:** no dependencies, and nothing on the render path that
  allocates. They build as Embedded Swift.
- **Blocks, with a reported latency.** Nothing assumes a per-sample callback, and every processor
  says how late it is. Hosted plug-ins need exactly this.
- **The engine runs at 48 kHz whatever the device does,** and the output converts. There is no
  sample rate setting, because it would change nothing anyone could hear.
- **The rack reads samples at its own rate,** where the reference reads everything at 44.1 kHz, so
  a sample plays at its own pitch.
- **The groovebox is a rack device.** Each machine has its own stereo output with strip parameters,
  as `GROOVEBOX_PORTS` has them on the web, which is what lets the rack take a song whole.

## Plug-ins

- **Plug-in formats stay out of the constrained targets.** In the graph, a plug-in module is a slot
  holding a C function and a context, which the host fills in. Nothing of any plug-in format
  reaches the audio targets.
- **A patch keeps a plug-in's state opaquely,** whether or not the machine opening it has the
  plug-in. A missing plug-in is named, silent, and kept exactly.
- **The rack's AUv3 exposes eight macros, not its knobs.** Its knobs come and go with the patch,
  and a host's automation needs parameters that stay put.

## One app on every platform

- **Pure Swift, one repository.** The Mac came first; Windows, Android and Linux followed.
- **The app's models live below the views.** `Session`, `RackSession` and the touch and desktop
  compositions are shared targets. Each platform supplies its parts through ports: audio routing,
  MIDI, file reading, plug-in hosting and memory. A platform's app is a small composition root.
- **The interface is drawn on the GPU layer rather than built from a toolkit** on Windows, Android
  and Linux. This suits an instrument, and keeps what the app depends on small.
- **The GPU layer asks only what Metal, Direct3D 11 and OpenGL ES 3.0 all do alike,** so a new
  backend never changes its protocol.
- **Shaders are written once, in GLSL.** Metal, HLSL and GLSL ES are generated offline, checked in,
  and checked for staleness in CI.
- **The drawn interface does not assume a mouse.** Hover, right click and a wheel are conveniences
  on top of what a touch can do, and sizes are in points.

## Touch

- **Phone first.** A phone shows eight steps a page, sets a 303 note on a keyboard as the machine is
  programmed, and has an edit mode and a perform mode. It stays upright: on its side it is too
  short for the grid and the knobs.
- **A tablet is a roomier phone.** The same touch layout is used at any width, and a desktop window
  as large keeps the desktop's.
- **The rack is drawn as a desktop draws it and moved about by hand,** pinched and panned, rather
  than laid out again. That is how a modular rack is used.

## Android

- **The render thread is kept to the big cores.** Left to the scheduler, it underruns. What a
  callback pays for is the rest of its cluster idling, not its clock.
- **MIDI to a device that is not USB is held in a scheduler until it is due.** Only Android's USB
  driver keeps to timestamps.
- **Foundation's internationalisation is left out,** since its ICU data is 30 MB per ABI and nothing
  uses it.

## The Mac app

- **One song open at a time.** The player owns the audio engine, the MIDI ports and the clock, and
  two of them would fight over one output. The right shape is one shared host with a song per
  window, which is worth building once comparing two songs earns it.
- **A rack's song is edited in the groovebox window,** linked so that each edit plays on in the
  rack, rather than in a second editor inside the face.

## Files

- **Songs are `.driftbox`:** the web app's documents byte for byte, under a name an operating system
  can associate without claiming every `.json`. `.song.json` and `.json` still open, and save back
  under the name they came with.
