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

   Then a pass over how it looks, because working was not the same as being the instrument. The
   web app's identity came across whole — its night indigo, smoked-glass panels, monospaced
   labels, one colour per machine, glowing steps and a teal playhead column — laid out as a Mac
   window: the transport in the toolbar, with tempo and swing dragged like knobs; the song as a
   strip drawn to scale and coloured by pattern; the grid stretching with the window, the 303
   lines on the drums' columns; knobs rather than sliders, in real units, one undo a turn; a 303
   strip, which the native app had not had at all; and the visuals as a dimmed backdrop behind
   everything, as on the web, instead of a letterboxed pane.

   Then the editing the web has and this did not. Phase 5 above says the chain had menus;
   the edits were ported and tested, but the interface never offered them, and a new pattern
   could not even be given a voice it did not already have. Now: the song strip's sections have
   a context menu — pattern, a pattern per machine, repeat, move, remove — and can be dragged
   into a new order, with a button to add one; patterns rename by double-click, and clear,
   duplicate and join the song from theirs; a lane can be added for any voice or 303 line; a
   pattern's length is dragged like the tempo; the PCF lane is on the grid; flams are marked in
   flam mode or with Option held, with the flam's width beside the switch; lanes and lines copy,
   cut and paste; each strip has its voice's swing. The edits the web keeps in `pattern.ts`
   are held to its own results as the others are; resizing and clearing a pattern live in its
   store, so they are held to that code by tests written from it. And the pattern being edited
   comes back at the next launch.

   Then the transport's own aids: a loop, set from a section's menu or the Transport menu and
   drawn as a bracket over the song strip, which the engine turns round on its exact frame and
   holds in bars so an edit keeps it; a metronome; and a count-in. The click is the reference's
   own spec, held to it exactly, and added after the master as it is there, so the pad cannot
   take it away. Two things turned up in the reference. Its count-in spent the song's first
   bar on the clicks — it counted transport bars, so bar one was heard as clicks and the song
   started at bar two; here the song waits at its start for the count-in and then plays from
   the top, and the reference now does the same (emmettl/driftbox#303). And its comment on the click's levels says
   they render at 0.70 and 0.50; in Chromium they render at 0.341 and 0.228, which the Swift
   click matches to six places, so the ratio the comment was after holds and the numbers in it
   do not.

   Then vibes, the web's performance mode: the visuals at full strength, the sidebar, the toolbar
   and the editor put away, the whole window a pad for the filter, a scope and what is playing,
   with play, the scene and the way back to the editor in the corners (⇧⌘P, or Esc to leave). And
   the scene can be chosen at last, from View ▸ Scene or by cycling through them, where before
   the app only ever showed the one the song named.

   Left: the 303's step entry from the keyboard; automation recording; and more
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
parity point.

1. ~~**The graph, the compiler, the first modules.**~~ Done. `DriftboxRack`, constrained like
   the engine: the patch types, `compile` — placeholders, port aliases, bypass, one cable an
   inlet with the last one winning, Kahn's order with cycles broken by the lowest index,
   polyphonic widths to a fixed point, input trims, delayed-cable and mono-fold notes — and
   `RackGraph`, which runs a plan a block at a time: knobs ramped across a block and flattened
   after, stepped ones jumping, changes scheduled to a frame, polyphonic sources collapsed into
   modules that run once, and the master stage of solo, mute, balance pan, the linked limiter and
   the tanh ceiling. Modules are one enum dispatched by `switch`, so the render path takes no
   existential and no class. The first twelve: Out, VCO, Noise, VCA, Mixer, Ladder, SVF, ADSR,
   LFO, Offset, S&H, Delay. Eighteen patches rendered by the reference's `RackRenderer` — every
   module, a feedback cycle, knob ramps with scheduled and stepped changes, the limiter driven
   hard with pan, mute and solo, a placeholder and a bypass, three voices collapsing into a mono
   Out — compile to the same plans and render bit-identically, block by block.
   One thing the port had to copy exactly rather than improve: the seeded random generator's
   FNV hash multiplies in doubles, which past 2^53 rounds before it is truncated to 32 bits, so
   the Swift does the same arithmetic. A true 32-bit multiply is a different noise, a different
   random LFO and a different S&H melody from the same patch — the test says so when it is tried.
2. ~~**The rest of the modules.**~~ Done, bar the groovebox. Thirty-five more, ported in
   parallel by family — shaping and dynamics, the effects, control and metering, the sources, the
   sequencers, the arpeggiator and the scale and chord players, and the Alligator and Vocoder —
   each family an enum of its own behind one case of `RackProcessor`, with its own fixture file.
   A module's context now carries the transport, its data slots, the host's input buses, a
   collector's per-voice inlets, jack presence and which voice of how many it is. 104 patches in
   all compile to the reference's plans and render bit-identically; every definition — ports,
   ranges, defaults, stepped and hidden flags, polyphony — is held to the reference's own export,
   which caught MIDI's and the looper's hidden params; `PatchCodec` reads and writes the
   reference's documents, byte for byte on every factory and song patch and twenty damaged ones;
   and each factory patch, played through the codec for a second at its tempo, renders
   bit-identically too. `RackHost` plays a patch in real time, swapping patches whole and cutting
   the graph's blocks to the device's.
   The groovebox as a rack module is left: it is the engine behind a faceplate, and comes with
   the host.
   What the porting found in the reference was fixed there (emmettl/driftbox#304) and here
   together: the looper's Stop recorded over the take, because Stop and the idle capture mode are
   both mode 0; the chord player hung the audio thread on a NaN or infinite pitch, looping for ever
   in `scaleNote`; drive and the compressor kept a NaN in their state for good where every other
   dynamics module resets; and the arranger's trigger was `Math.round` of a millisecond where every
   other module's is `Math.ceil`. The fixtures cannot feed a NaN, so `RecoveryTests` holds the port
   to those fixes.
3. ~~**A host and the panels.**~~ Done. The rack has a window of its own (⌘3), playing through
   the same device as the song. Its front is every module's generic faceplate — a knob for a
   range, buttons for a choice of three, a stepper past that — sized and stacked exactly as the
   reference's `layout.ts` and faceplate table do it; its back is the bays, the jacks and the
   cables, hanging and swinging as `cable.ts` has them, all held to the reference's own numbers
   for every factory and song patch. Drag jack to jack to patch, from either end, and it snaps;
   click a cable's belly or the × by its inlet and it goes up in smoke; drag a bay to move its
   module, and its cables jiggle behind it. Tab turns the rack round, space runs its transport,
   and the typing keys play it through the reference's own voice allocator. Modules come from a
   picker of every shelf, with each module's picture and line of copy exported from the
   reference's definitions; the factory patches are in the header; edits undo one turn of a knob
   at a time; and the patch is kept between launches.
   Then the first of the hand-built faces, one for one with the reference's: the VCO (its tune
   knob big, its pulse width asleep off a pulse), the Ladder (pink where it squelches), the Out's
   channel strip, the MIDI module saying what it last heard, and the three that meter — the
   Chromatic Tuner's note and needle, the VU Meter's moving coil, lights and scope, and the Loop
   Station's screen and transport. What they show comes off the render thread without it
   allocating: every eight blocks, as the reference's worklet posts them, each metered module's
   numbers and short buffers are copied into a mirror of its own under a sequence count, and the
   interface takes readings from the mirrors — by the modules' own code, so a live reading is
   exactly the one the conformance-tested module gives.
   Then the faces that edit what a module plays: the Tracker's lanes, the Arranger's song, the
   Scale Player's map and the Note Echo's pulses. They write the module's data, which now reaches
   the sound on the next block while it plays: the host swaps a new buffer into the slot from the
   render thread, whole, so a module never reads a new pointer with an old count, and frees it
   with the graph. A drag is one step of undo. The Tracker's lane tags cycle the lane's mode,
   which the reference's face shows but cannot change.
   Then the Chord Player (the eight voices a setting makes, named, and a held Alter), the Arp
   (sixteen rhythm steps showing the figure's notes, over all seventeen of its controls) and the
   Combinator (its rotaries and buttons, what each drives, and the whole routing written out).
   The chord and figure previews are held to the reference's own over a grid of settings: 2,520
   chords and 960 figures, exactly.
   Then MIDI from outside plays the rack while its window is in front, and the groovebox
   otherwise: notes through a keyboard of their own on each channel, so two controllers do not
   steal each other's voices, and the mod wheel, bend, pressure, expression, breath and sustain
   to the modules listening on that channel — the reference's decoding, byte for byte.
   Then samples: a file dropped on a Sampler, or chosen, is read at the rack's own rate — so,
   unlike the reference, which reads everything at 44.1kHz, it plays at its own pitch — mono and
   loud, and the tempo becomes the one at which it is whole bars. The breaks the factory patches
   are built around are rendered from the 909 as the reference renders them, off the main thread,
   and every sampler without a file of its own gets its patch's. The host keeps loaded audio
   beside the patch, where the reference keeps it too, and points every graph it builds at it, so
   a structural edit does not lose it.
   Then the Multisampler's Key Atlas — a set of recordings dropped on it maps itself by the names
   the reference reads (Piano_C3_pp, vel064, midi 72), held to its own reading of a spread of
   names — and the Audio Track, a recording placed at a bar and a step.
   Then the Combinator finished: its routings drive their knobs as a rotary turns, where before
   they applied only when the graph was rebuilt, and a knob a routing drives is marked. The
   routing is edited in an inspector beside the rack, showing what each routing puts on its
   target as it moves, and each rotary learns a controller, the binding kept beside the patch.
   Then a trim pot by every inlet on the back, bipolar, lit when it is off unity: turned
   within its travel it reaches the sound through a slot of its own, and only leaving unity or
   coming back to it rebuilds, as the reference's compiler spends a slot only on a pot doing
   something. Each pot is a slider to VoiceOver.
   Then the rack as an Audio Unit, as the engine is one: the window plays it through
   `RackAudioUnit` in the app's `AVAudioEngine`, rendering the same host bit for bit, carrying on
   through the engine stopping and starting on a change of device, and saving and restoring its
   state as the patch document — what an AUv3 extension will ask of it. It plays at its host's
   rate and refuses any other, since the rack's audio is decoded at that rate; MIDI as render
   events and a parameter tree for a host to automate are for the extension itself.
   Then the groovebox as a module, begun: the engine gives each of a song's four machines outputs
   of its own, which feed the mix unless a host diverts one, as the web engine's `sectionOutputs`
   do; and the `groovebox` module takes them from the host's buses 0 to 3 through a strip of level,
   pan and mute onto a stereo outlet each, metering each machine after its strip, held to the
   reference's samples and its meters' arithmetic.
   Then the rack plays its patch's song beside itself, as rack mode does: an engine of its own whose
   mix is added to the rack's, whose machines reach the `groovebox` module on the host's buses,
   whose patched machines leave its mix, and which starts from the top and stops with the rack's
   transport, at the patch's tempo or the song's, with the song's swing, keeping its beat through
   an edit. Then the app: a groovebox song opens in the rack whole, from the song in the groovebox
   window or the catalogue, with its source wired in; the Groovebox face has each machine's strip
   and meter and the song's arrangement, section by section, to start from or loop; the song is
   edited in the groovebox window, linked so each edit plays on in the rack, rather than in a
   second editor in the face as the reference has it for want of another window; and the rack says
   what it holds, as the reference's three states of compatibility do. The rack is at parity.

## Help and tutorials

Not yet: worth doing once the app is complete enough that the help would not be rewritten with
every milestone. Then, everything the web app teaches with, and what a Mac does better:

- **The reference's teaching, ported:** its help dialog, the first-run offer of a tour, the guided
  tour and tutorial coach that walk a patch being built, and each module's guide. The words carry
  over; the coach marks become the app's own popovers, pointing at real controls.
- **A Help Book**, so the Help menu's search finds topics, and finds menu items by name as every
  Mac app's does; with anchors, so a `?` beside a panel opens the page about it.
- **Help tags everywhere a control's purpose is not its label**, as most already have.
- **Tutorials that play**, in the groovebox and the rack: a song or a patch built a step at a
  time, each step heard before the next, as the reference's coach does.

## Milestone 3 — what only native can do

Plug-in hosting (Audio Units first, which work on iOS too; VST3 on the Mac), AUv3 export,
external displays, performance capture to video.

1. **Plug-in hosting.** ← *here.* Begun: the rack's `plugin` module, which the reference has
   no counterpart to and keeps as a placeholder. In the constrained graph it is a slot holding a C
   function and a context, which the host fills, so nothing of any plug-in format reaches the
   audio targets; empty, or with the plug-in missing, it is silent. `RackHost` keeps each module's
   processor as it keeps loaded samples, so every graph an edit builds runs the same instance
   with its state intact, and swaps one in or out on a block boundary. On the Mac,
   `HostedAudioUnit` readies an Audio Unit effect in stereo at the rack's rate and renders it on
   the rack's thread through its own render block, with the rack's tempo, beat and transport for
   a unit that keeps time. A patch keeps the unit's component and its document state, in base64,
   whether or not the machine opening it has the unit.
   Then the app: the module is on the picker's Effects shelf, and its face chooses from every Audio
   Unit effect on the Mac, by maker; says who made the unit and how late it is; and opens the unit's
   own interface in a window, or the system's generic one where it draws none. Choosing a unit is a
   step of undo; the unit's own settings are its own, so undoing in the rack never changes them,
   and they reach the patch shortly after they change. A unit the Mac lacks is said to be missing,
   silent and kept exactly.
   Then instruments: the `plugin-instrument` module, on the Sources shelf and wired to the keys as
   it arrives, turns every voice of the rack's pitch and gate into notes for an Audio Unit
   instrument, at the frame they happen and at their velocity, gliding pitch ending one note for the
   next, with mod, bend and sustain beside them; a new instance lets go of whatever an old one left
   sounding. The notes reach the unit through its own MIDI scheduling, ahead of each block, and its
   face shows what it has sounding on a strip of keys. Timing notes to the frame found a bug in the
   reference's graph, fixed there (emmettl/driftbox#309) and here together: a stepped param changed
   partway through a block kept its old value at the head of every block after, so a held gate
   retriggered every block.
   Then macros: four knobs on either plug-in module, each with a CV inlet, mapped onto the unit's own
   params — chosen from its tree of them, or learnt by moving one in its interface — and kept in the
   patch by each param's key. Being ordinary params, they undo, learn a controller, take a
   Combinator routing and record as automation like any other knob. The render thread sends a
   macro that moves, knob and CV together, to its param once a block, across the param's range as
   the unit shows it, logarithmic for a frequency; a version 2 unit drops a ramped change, so none
   is ramped. A knob names what it turns and says its value in that param's words.

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

## Milestone 4 — Windows

The constrained core, the documents and the hosts were written with no platform in them, and on
Windows they turned out to be exactly that: they build there, and every conformance test passes,
the whole mixes against Chromium included. What is left is the platform, in the order that makes
each step stand on the last. The README's "Platforms" says how it is divided.

1. ~~**The core on Windows.**~~ Done. Three small fixes (the C library's name, a thread clock, the
   emitter's paths and line endings) and 120 of 120 tests.
2. **Audio and MIDI behind ports.** Done on Windows. `DriftboxHost` declares what a platform's audio and
   MIDI must do — `AudioRouting`, `MIDIInputPort`, `MIDIOutputPort`, `HostTime`, `RenderSource` —
   and `DriftboxHostWindows` does it with WASAPI and WinMM, tested against the device and against
   the clock. `driftbox-play` plays the catalogue through it. Then the parts of `Player` that are
   not views, into `DriftboxSession`, a target every platform shares:
   - `Session` is `Player` on the ports, with its own undo, since Windows' Foundation has no
     `UndoManager`, and settings kept under the Mac app's own keys.
   - `ClockCursor` and the catalogue of songs moved there too; the Mac's `Player` reads them from
     it.
   - `Player`'s tests of its logic run against `Session` on every platform.

   Then the Mac's adapters into `DriftboxHostMac`, conforming: `AudioRoute` is the Mac's
   `AudioRouting`, summing its sources through the `Mixer` into one source node in its engine, and
   `MIDIInput` and `MIDIOutput` are its MIDI ports, on `HostTime`'s clock and the shared
   `MIDIDestination`; the Audio Units — the engine's, the rack's, and those the rack hosts — go
   with them, leaving `DriftboxHost` with nothing of any one platform. The rack's model moved onto
   `RackSession` already. Then the groovebox moved onto `Session`, `Player` gone: a `Studio` makes the
   Mac's adapters and hands them to the two sessions, which play as sources on one route — the
   engine's and the rack's Audio Units are for plug-in hosts now, not the app — and one timer ticks
   both. `Session` took on what only `Player` had: the rack's song linked for editing, and MIDI
   handed to the rack while its window is in front. Undo is the session's own history, one step an
   edit, as on every platform.
3. **A GPU layer under the scenes.** ← *here.* The scenes use a small part of Metal: buffers,
   render pipelines, per-draw constants, indexed draws, depth, blending. `DriftboxGPU` says that
   much and no more, in what Metal, Direct3D 11 and OpenGL ES 3.0 all do alike — sprites as
   instanced quads, vertex data as attributes — and `DriftboxGPUD3D11` answers it, held to
   `GPUContractTests` on WARP. The shaders are written once, in GLSL, and `scripts/shaders.mjs`
   makes Metal, HLSL and GLSL ES from them with the Vulkan SDK's glslang and SPIRV-Cross, and the
   uniform blocks' Swift structs from its reflection; all of it checked in, and checked for
   staleness in CI. Then surfaces — a window's swap chain behind `GPUSurface`, and `Presenter` —
   and the first scene across: `PulseScene` on `GPUScene`, its shader the Metal one's GLSL, held to
   the Metal one's test, and on screen in `driftbox-play --window` with the song playing. Then
   `DriftboxGPUMetal`, held to the same contract on the Mac's GPU, a `CAMetalLayer` behind
   `GPUSurface`, `PulseScene` held pixel for pixel to the Metal `Pulse`, and `--window` on the Mac
   too. Then the nine surface scenes on `GPUSurfaceScene`, their MSL back in GLSL, with cards as
   instanced quads. Each is held on WARP to drawing and moving, and on the Mac to its Metal scene
   frame by frame. `GPUScenes` finds them by a song's `visual`, and `driftbox-play --window` shows
   them on Windows, with the mix's levels and the score's position as the Mac feeds them.
   `Timeline` moved from the app to `DriftboxSeq` for that. Then sixteen of the seventeen geometry
   scenes on `GPUGeometryScene`:
   - The camera and the geometry helpers are out of `canImport(Metal)`, on `Matrix4` rather than
     `simd`, and the Metal scenes use the same code through a bridge.
   - Sized points are sprites: instanced quads, sized in pixels by `sprite.glsl`.
   - Each scene is held on WARP to drawing and moving through the Metal scene test's six seconds,
     and on the Mac to its Metal scene frame by frame.
   - Pipelines cull and test depth as three does: `GPUCull` against three's counter-clockwise
     front, which Longhand culls to (the Metal Longhand culled against Metal's clockwise front and
     kept its tubes' far walls), and `GPUDepth.test` for three's `depthWrite={false}`, which
     Convoy's dust and Machine's sparks use. Both are in the contract tests.

   Left:
   - A Core Text typesetter for the Mac, so that Graphic Lab sets its type there too. Graphic Lab is
     on the layer now, printed on `DriftboxCanvas` with DirectWrite's type on Windows and Android's
     own on Android. Only glyphs are a platform's; the canvas is drawn on the layer, where the
     Windows app's interface will draw too.
   - `--window` on the Mac showing the song's scene rather than Pulse, and the Metal `Scene`
     gone at the end.
4. **The window, drawn.** ← *here.* The shell first: `DriftboxShell` says what the app asks of a
   window in platform-neutral terms — pointers, keys and scrolling as events in points, a menu bar
   as data with shortcuts on the platform's own modifier, file panels, a loop that keeps drawing
   through a resize, and `post` — and `DriftboxWin32` answers it, tested against a hidden window.
   `driftbox-play --window` uses all of it on Windows. Then the Windows app itself, as a
   composition root of its own: `DriftboxWindows` chooses Windows' parts and hands them to
   `DriftboxDesktop`, the app on `Session` that every platform with a `ShellWindow` runs, with its
   settings as menu items the shell ticks, and unsaved work asked about before it goes. Then the
   interface, drawn on the GPU layer rather than built from a toolkit, which is in keeping with an
   instrument and keeps what the app depends on small. `DriftboxInterface` draws it on the canvas
   in points, laid out afresh each frame from the session and hit from the same layout, so that
   Android's touch interface can share it: the transport bar and the step grid so far — drum
   lanes, the filter's lane and the 303 lines, scrolling when taller than the window — over the
   scene as smoked glass, with the View menu's Show Controls (Tab) taking them away to perform.
   The canvas gained rounded panels with a fill that runs top to bottom, borders, and type set at
   the size it lands under an even scale, so that the interface is as sharp at 150% as at 100%.
   The keyboard plays as the Mac's does, and a voice selected has its panel of knobs down the
   right, turned by dragging, on arcs the canvas draws. The song is a strip of its sections to
   play from, with the loop bracketed over it, and the grid is headed by its patterns, to follow
   or choose or add to. FX puts the song's effects in the voice panel's place, in their groups.
   The tempo and the swing are numbers dragged in the transport, as a data wheel sets them. The
   secondary button gives a lane, a 303 line, a section or a pattern its menu, as Windows shows
   one: turning, transposing, clearing, copying, loop lengths, repeats, moving and removing.
   A section's menu gives each machine a pattern of its own there, dotted on the strip; a pattern
   is renamed in its chip; and steps wider than the grid scroll sideways under the lanes' names.
   Left: settings, and the rack and its cables.
   The rack comes by way of `DriftboxRackSession`, which holds what the Mac's `RackModel` did —
   the patch, its edits and undo, the keys, controllers, samples, song and transport — on every
   platform, with the Mac's audio, plug-ins and file reading behind ports: `AudioRouting`,
   `RackPluginHosting` (none on Windows yet, so plug-ins there are kept and silent) and
   `SampleDecoding` (a WAV reader of its own by default). The Mac has moved onto it: its window
   edits a `RackSession`, held by a `MacRack` with what only a Mac has around it — the rack's Audio
   Unit, Audio Units as its plug-ins, Core Audio reading its samples and the groovebox window — and
   its own copies of the model, the helpers and the patch catalogue are gone.
   Next: the rack drawn on the canvas, its fronts, its back and its cables.
5. **Shipping.** Begun. The program has its icon, drawn from the web app's and linked in as a
   resource; it opens a song it is handed, and `--register` makes `.driftbox` files open in it for
   the current user. `scripts/windows-package.mjs` makes a folder that runs without Swift
   installed: the program, its resource bundle, and the runtime DLLs it loads, found from their
   import tables. Left: signing, winget, and an installer to register the type. Songs are already
   `.driftbox` — the web app's documents byte for byte, under a name
   Windows can associate without claiming every `.json`. `SongFile` in `DriftboxDocument` holds
   the rule for every platform: saved as `.driftbox`; `.song.json` and the web's `.json` still
   opened, and saved back under the name they came with.

## Milestone 5 — Android

This started as a question and was answered by compiling. The Swift 6.4 toolchain for Windows
ships an Android platform. With it, the four constrained targets compile unchanged for arm64 and
x86_64 Android, optimised and so with the allocation checks, and without the NDK: the
`@_extern(c)` branch in `Math.swift` that serves the bare Embedded build serves Android too. At
link time they need libm, `malloc`, `free` and the `mem*` functions, all of them in Bionic.
Then the engine ran on a phone (step 1).

So the port is the platform again. Most of it is Milestone 4 over again with a third answer to
each question, and the rest is Android's alone:

1. ~~**The core on a phone.**~~ Done. A `canImport(Android)` branch beside `ucrt` wherever a host
   imports its C library, the bench moved out of the Mac's branch of `driftbox-play` so that every
   platform has it, and `scripts/android-bench.sh`, which builds the bench for arm64 and runs it
   over `adb` on each kind of core. On a Fairphone 6, a mid-range phone, a big core renders the
   catalogue at 13 to 16% of real time, four and a half times the Mac. A little core cannot keep
   up at all. Paced like a device, the big core costs 67%, but only because its core goes idle
   between calls; with the cluster kept busy, the paced cost is 17.7%. (This said the governor's
   clock at first. Step 2 found the clock makes no difference.) Making the engine and loading a
   song there takes about four seconds before the first render, which an app switching songs
   would feel; where that goes is not yet looked at. The rack's load is not measured yet.
2. **Audio and MIDI behind the ports.** ← *here.* Audio is done. `DriftboxHostAndroid` answers
   `AudioRouting` with AAudio: low-latency, exclusive, a buffer that starts at one burst and grows
   a burst at a time on underruns, and a stream that asks to be replaced when its device goes.
   `Mixer` moved into `DriftboxHost` for it, so Windows and Android sum their sources the same
   way, tested everywhere. `scripts/android-play.sh` plays a song through the phone. The render
   thread is kept to the big cores, which is what keeps it in time: left to the scheduler it
   underran a hundred times a second, and kept to them the heaviest song played thirty seconds
   without one, 4.8ms from render to speaker. It also reports to a performance hint session.
   That was meant to hold the clock up, and it does when its target is tight. But the render
   costs 60% of each 2ms burst at any clock, against 15 to 18% when the other big cores are busy:
   what a callback pays for is its core waking cold. There is room in that, but less than the
   bench promised, and the rack and the scenes will want some of it. Left: one device until the
   app can list them from Java's `AudioManager`, and a stream lost to a device going is handled
   but not yet seen to be, for want of anything to unplug.
   Then MIDI, heard. `AMidiInput` and `AMidiOutput` answer the MIDI ports with Android's native
   MIDI, which needs Android 10, so the build moved from API 28 to 29. Input is a thread asking
   each port in turn, framed by `MIDIByteStream` in `DriftboxHost`, which is tested everywhere,
   and stamped with the time each packet carries, on `HostTime`'s clock. Finding and opening a
   device can only be done from Java, so the app does it and hands each device to `AMidiDevices`,
   and Swift does the rest. `scripts/android-app.sh midi-loopback` tests the ports against
   Driftbox Loopback, a MIDI device the app publishes that sends back what it is sent: notes,
   running status, system exclusive and clock all come back as they should, stamps exact.
   What it found: a stamp is only kept to by a device that keeps to stamps. Android's USB driver
   does, by its source; a device that is another app is handed a message at once, so a clock sent
   a tenth of a second ahead arrived a tenth of a second early, and a flush dropped nothing. The
   roadmap said clock out would need no scheduler of its own, and for another app it does.
   So now `AMidiOutput` holds every message for a device that is not USB in a scheduler of its
   own until it is due, and sends it stamped, as WinMM's does; the two share `MIDIQueue` in
   `DriftboxHost`. Its thread waits on a condition against `CLOCK_MONOTONIC`, at urgent audio
   priority and kept to the big cores, and sends a beat of clock 0.1 to 2ms after each tick was
   due. Left: a USB device, measured with a controller, to see its driver keep to the stamps.
3. **A third backend under the GPU layer.** ← *here.* `DriftboxGPUGLES` answers `GPUDevice` with
   OpenGL ES 3.0 through EGL, on the GLSL ES the shader generator already writes. It passes the
   contract's checks on the phone's Adreno, first time, through `scripts/android-app.sh gpu`, and
   runs the contract tests themselves in CI on Linux, on Mesa's software rasteriser. Getting there
   took swift.org's Swift SDK for Android in place of the installer's Android platform, whose
   standard library had no SIMD types. Then Pulse on the phone's screen: a surface on an Android
   window, which turns the frame right way up on its way to the screen, and the app opening on a
   song with Pulse drawn from it at the display's 120 frames a second and the screen for a pad.
   Drawing kept the audio's cores awake, and the render thread's cost fell from 60% of each burst
   to 25 to 40%, as step 2 said it would. Then every scene on the layer: the nine surface scenes
   and Pulse, each the one its song names, fed the mix's spectrum as on Windows, and each passing
   `scripts/android-app.sh scenes` on the Adreno — drawn, not black, moving. At every pixel of the
   phone's screen Frost took 21ms a frame and two more over the display's 8.3; drawn at two
   pixels to a point, as a Retina Mac draws them, and scaled up, nine keep 120 frames a second and
   Frost 98. Then the sixteen geometry scenes, as they moved to the layer on every platform at
   once: each passing on the Adreno, at no more than 3.2ms a frame drawn. Then type: a
   `Typesetter` on Android's own text stack, reached through the app's Java from whichever thread
   draws, and passing what `TypesetterTests` holds every platform's to. Then Graphic Lab on
   `DriftboxCanvas`, its type set by that typesetter, so that all twenty-seven scenes pass on the
   Adreno; Graphic Lab takes 5.6ms a frame drawn, warm, and 6.8 over its first sixty frames at a
   size, while its glyphs go into the atlas.
4. **The touch interface, designed with iOS.** See below.
5. **Shipping.** The shell is a `GameActivity`, which hands the window, input and lifecycle to
   native code. Songs open and save through the storage access framework as `.driftbox`, and
   the SDK's own tools package the `.so`, as `scripts/android-app.sh` has done since step 2's
   loopback, without Gradle; begun with a plain `Activity` and Java's MIDI devices handed to
   Swift, and a package of 8MB: Driftbox and the Swift runtime 6.9MB stripped, the NDK's C++
   library 1.4MB. Out of view it plays on through a media playback service, which keeps the big
   cores Android would otherwise take away, with a buffer of sixteen bursts while nothing is
   drawn, and pauses when audio focus is lost. The build leaves out Foundation's
   internationalisation, which is 30MB of ICU data per ABI that nothing here uses:
   `DriftboxDocument` takes Foundation only to write a WAV. The Play Store, or F-Droid, when
   Driftbox is public.

### The touch interface

A groovebox of four machines and a rack full of cables were laid out for a desktop's screen and
a pointer. A tablet and a phone need them designed again: what is on screen at once, what a
finger can hit, what a drag means when there is no hover and no right click, and where the rack's
cables go at arm's length. That design is the same work on iOS and Android, so it is done once,
for both, tablets first.

The implementations may well be two, built in parallel: SwiftUI on iOS, where the Mac's views
are most of the way there, and the drawn layer on Android. What carries across is then everything
under the views: the layouts' arithmetic (as `RackLayout` already is, though it sits inside
`DriftboxApp` today), hit targets, each gesture as a small state machine, and undo. That lives
below the views, in a target both platforms build, and is tested once.

Begun on the drawn layer, since the desktop's interface arrived there first: `DriftboxInterface`
is drawn on the canvas in points and takes pointers, and `DriftboxTouch`'s `Touchscreen` puts it,
the session and the scene together for a touch screen, as `Desktop` does for a window. The Android
app is that now, and the desktop's layout on a phone's 372 points says what the design has to
answer: ten of a pattern's sixteen steps fit across and the rest cannot be reached, a step is 22
points wide where a finger wants 44, the 303's notes are rows 7 points high, the grid scrolls only
with a wheel, and a context menu is a right click. Drawing the controls over the scene costs a
frame now and then at 120 a second.

### What Milestone 5 asks of Milestone 4

- **The GPU layer takes a third backend** without its protocol changing. Nothing goes in it that
  OpenGL ES 3.0 cannot do, which rules out little the scenes use.
- **The shaders are written once.** Before the HLSL is written, settle on one source and generate
  the other languages from it offline, for example HLSL through SPIR-V to MSL and GLSL ES. The
  generated shaders are checked in, and a check fails when they are stale, as `emit --check`
  does for the fixtures. The offscreen renders hold all three to the same image.
- **The drawn interface does not assume a mouse.** Hover, right click and a scroll wheel are
  conveniences on top of what a touch can do, never the only way to it. Sizes are in points, not
  pixels.
- **The views' logic moves below the views.** Step 2's move of `Player` out of `DriftboxApp`
  goes further: whatever an interface decides that is not drawing goes in a target that iOS,
  Android and the two desktops share.
