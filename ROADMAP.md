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
2. ~~**DSP and the drum voices.**~~ Done. All 22 voices render, in stereo, within tolerance of
   Chromium: the parameter timeline, the biquad, wavetable oscillators, noise (resampled too),
   the 2x-oversampled waveshaper and pan. What is left is the listening pass — which needs
   something to listen with, so it comes with the offline song render in phase 3.
   What was planned: `ParamTimeline` — the Web Audio automation calls, per sample —
   then biquad, oscillator, noise, and the `VoiceSpec` interpreter. The 22 voices are data handed
   to one interpreter, so this is one interpreter and a set of small functions rather than 22
   synths. Done when each voice renders within tolerance of the browser, and a listening pass.
3. ~~**The 303s, strips, sends, master, the performance filter.**~~ Done, with two things
   carried forward. The 303, both sends, the master inserts including the browser's compressor,
   the performance filter, and `SongRenderer`, which wires them together as `renderMix` does.
   Four of eight catalogue songs match the reference whole at -80 to -98dB, and the listening
   pass — thirty seconds each of two songs through `driftbox-render` — came back "sounded fine".
   Carried forward: the channel-count effect in Chromium's delay loop that the other four songs
   trip over, and effect and tempo automation in the offline render, which nothing in the
   catalogue uses and which the renderer refuses rather than ignores.
   What was planned: Done when whole songs match
   `renderMix` by spectral fingerprint.
4. ~~**A real-time host on the Mac.**~~ Done, bar two things. Every real-time form is held to
   its offline one rather than to the browser again: the drum voices and the 303 to the bit,
   the reverb within single precision, the whole engine within -90dB. `driftbox-play` hosts the
   engine as an `AUAudioUnit` in an `AVAudioEngine` and plays the catalogue. Carried forward: the
   engine costs 3.3% of real time in a loop and a fifth of the audio's time on the live IO
   thread — the difference being what waking a core every ten milliseconds costs, measured by
   pacing the loop the same way, and not the code. (The events ring — which voice,
   accents, notes, passes — and the reverb's second stage landed with phase 5.)
   What was planned: `AUAudioUnit` from the start, sequencing sample-accurately
   inside the render block, lock-free rings both ways. The ring back to the interface carries
   *events* — which voice, accents, slides, sections — not only levels, so scenes can react to
   what was played rather than to a spectrum. Done when a bare player plays the catalogue.
5. ~~**The editor.**~~ Done. Begun as the Mac app itself, a SwiftPM executable wrapped into a
   bundle by `scripts/bundle-app.sh` (which the resource bundle needs, or `Bundle.module`
   asserts). Looked at, once, and three things came of it: a transport pushed above the window
   and a grid centred in its scroll view (layout, fixed); a main thread that re-planned the
   whole song every frame and then spent what was left re-diffing four hundred grid cells (the
   step times are planned once, the tick writes only what changed, the 303 grid is a canvas);
   and a stopped song that drifted with the engine's clock, thirteen bars in twenty-five
   seconds (held in place, tested). It now plays the catalogue with the scene running and the
   voice names flashing. In so far:
   the catalogue as a library; open and save of the web app's documents; a transport with the
   bar, step and pattern it is on, and the chain as a strip to jump around; the step grid of the
   pattern playing, live and editable; the 303 grids, with pitch, accent and slide; a panel of
   knobs and sends per voice, and the effects; the pad; undo of every edit; export of the mix to
   WAV; voice names that flash from the engine's events ring; and every edit in `pattern.ts` —
   the pattern list, rotate, transpose, randomise, alter, clear, loop lengths, flams, the chain —
   ported and held to the reference's own results on 28 edits, with a pattern picker, lane and
   line menus, chain menus, tempo and swing on the interface; keys, the number row striking
   the drums and the home row playing 303 A; stems, one WAV per voice; and CoreMIDI — notes
   from any source play the keys, and a **sync** button follows an external clock's tempo,
   start, stop and position, the estimator held to the reference's on a synthetic stream of
   464 messages. Then MIDI clock *out*, held to the reference the same way, and the document
   model, which turned out to be the same job as making the app a Mac app and went into phase 7.
6. ~~**Visuals.**~~ Done. `DriftboxScenes`: a `Scene` protocol keeping the web scenes' ids
   and accents, a `SceneRenderer` over one compiled shader library, and Pulse, the fallback: a
   dark field that breathes with the level, a bloom and a ring on every kick, a flash on a
   snare, a horizon that sparkles on hats, a 303 note as a line at its pitch, the pad's cursor.
   Then the web's nine surface scenes, ported shader for shader — Orrery, Switchback, Daydream,
   Small Hours, Paper Cities, Weave, Frost, Hothouse, Night Bus — over an `Analyser` that is the web's
   `AnalyserNode` on a mono tap of the mix, and a score position read from the engine at the
   display's rate. Every scene is drawn offscreen by a test and, with an environment variable,
   written out as PNGs; the eight were checked against the web's by eye that way, and Small
   Hours and Paper Cities seen live in the app. Then the geometry layer — `Camera`, three's matrices with Metal's depth range, and
   `GeometryScene`: buffers, pipelines under three's blend modes, a cleared background — with
   Wireframe, the Rez corridor, as its first scene: one line list of sixty-four ribs and their
   rails, moved in the vertex shader. Then Sunset (the chillwave slatted sun and its
   wireframe floor, on plane geometry with a model matrix and a looking camera) and Web (Tempest
   2000: sixteen lanes, sixteen bands, a finger as a black hole). Then Saturn, the first that is an object rather
   than a place: two point clouds, Keplerian rings, and kicks that punch scars into the planet
   — which brought point sprites, onset detection and the framing helper with it. The camera's
   defaults are the web canvas's own (fov 60, far 200, at (0, 1.15, 6)), because a scene that
   never sets one is relying on it. Then Lifeforms, seven noise-deformed
   icosahedra breathing on the low end, which brought three's icosahedron with it. Then Cubik, the first solid one:
   729 instanced cubes in a paper-white room, which brought a depth buffer, box geometry and
   instancing with it. Then Stillwater, the one that reads events
   rather than levels: rings dropped on black water by an onset detector, and a camera aimed
   by its own angles. Then Light Cycles, whose walls are rewritten
   every frame and whose bikes turn on the beat. Then Clouds and Longhand. Then Defcon and Dancers. Then Convoy and Machine — the last being the only lit
   scene, with three's standard material approximated under an ambient, a directional and a
   point light, and the one place three's fog is actually applied. All twenty-seven.
   One thing Longhand wants that the native side does not have yet: the web samples the pointer
   at its own rate, 120Hz on a ProMotion screen, so a flick that begins and ends between two
   frames is still drawn. `SceneInput` carries one touch a frame, so a fast hand draws a
   coarser line here. It needs a touch history on the input, which is a change to make when a
   second scene wants one.

   One thing the porting found in the web, not in the port: Defcon builds its land fill with
   `rotateX(PI/2)` and then `scale(1, 1, -1)`, which puts it at z = -y, while the coastline
   outline is pushed straight through at z = +y. The outlines are mirrored across z from the
   landmasses they belong to, and since the blobs are not symmetric it shows. The scale is not
   removable — laid flat by the rotation alone the triangles face down and a front-side
   material draws nothing, so it is doing double duty as a winding fix — which makes following
   it with the outline the safe direction. Fixed in the web as emmettl/driftbox#300 and here
   at the same time, so the two do not disagree while that waits.

   The Jumpman port found a second. Monsters and pick-ups are drawn at
   `m.x - scroll - across / 2 - 4` but spawned their shards at `m.x - scroll + c.x - 4`, missing
   the `- across / 2`. This roadmap first said that threw the pieces off the edge where nobody
   saw them; that was wrong, and repeated from the port's report after checking the missing term
   and not what it did. He stands left of centre and only stomps what is under him, so the
   pieces burst out of empty air about a fifth of a screen *right* of centre — on screen, and
   plainly in the wrong place, as a staged stomp showed. Fixed in the web as
   emmettl/driftbox#301 and here with a test that fails without it.

   And a third: in portrait Graphic Lab sized its section names from the page's height and never
   fitted them to a width, so Type Press ran over its tempo, Xerox Night off its slab and out of
   the page, and Live Signal to the very edge; and the broadcast edition, alone of the three,
   had no portrait branch, so its footer ran into itself. Fixed in the web as
   emmettl/driftbox#302 and here. The names now go through the scene's own `fittedText`, which
   only squeezes, and every edition rendered at 1920×1080 is byte-identical before and after.

   What was planned: a thin Metal layer — lines, instanced meshes, full-screen and compute
   passes — and the scenes reinterpreted one at a time, with a fallback for any a song names that
   has not landed.
7. **The Mac app proper.** ← *here.* The engine and the scenes were done; what was missing was
   everything that makes a thing a Mac app rather than a window with controls in it. Most of it
   is in now. A menu bar, which there had not been at all — and whose absence was not cosmetic:
   `UndoManager` was wired up and working, and with no Edit menu nobody could see that it
   existed. A window that knows its song: title and proxy icon, the edited dot, Save against
   Save As, recent documents, a prompt before replacing unsaved work. Songs opened by dropping
   them on the window or from the Finder, with the type declared. Settings behind ⌘, for which
   MIDI sources to hear — per source now, and live as devices come and go — where the clock
   goes, and whether the visuals run. The visuals in a window of their own, full screen on a
   named display from the View menu, drawn once a frame by one renderer so that the pane in the
   main window is an honest preview of the output rather than a second scene that looks
   similar. And both the song and the visuals window back where they were at the next launch.

   The output device is chosen in Settings too, and kept to: an interface that is unplugged
   plays through the system's device until it is back, and says so rather than going quiet.
   Doing it turned up two older faults. `AVAudioEngine` stops itself whenever its device
   changes and nothing started it again, so the sound went at the first change of output and
   stayed gone. And stopping the engine deallocates every unit in it, which threw away the
   engine host and the song with it; the unit now keeps its host across a stop and a start, and
   makes a new one only if the sample rate really has changed, carrying the song over at the
   same time rather than the same frame. There is no sample rate setting, on purpose: the engine
   runs at 48 kHz whatever the device does, the output converts, and a choice there would
   change nothing anyone could hear.

   Left: the pattern being edited, which restoration does not put back; and more
   than one song open at once, which is deliberately not done. It is not a scene change: the
   player owns the audio engine, the MIDI ports and the clock, and two of them would be two
   engines fighting over one output and two sources both called Driftbox Clock. The honest
   shape is one shared host with a song per window attached to it, and it is worth building
   when a second window earns its keep — comparing two songs — and not before.

   Also open, and not mine to decide: following an external clock and sending one are still
   kept apart. The loop that first made them exclusive, the app hearing its own clock come
   back, is gone — the input no longer hears the app's own source — and what is left is a
   choice between guarding against a loop through somebody's MIDI thru and allowing a master
   clock to be relayed on to other gear.

   Built so iOS stays possible — the split between `Player` and the views is the line it would
   fall along, and everything AppKit is in the app target — but not built for iOS yet.
8. **iOS.** Deferred until the Mac app is done. Audio session, background audio, a layout that
   opens into the visuals, haptics, Now Playing, and the AUv3 extension the phase 4 audio unit
   already is.

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
