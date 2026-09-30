# Roadmap

What Driftbox's native port has now, what is left before its first release, and what is kept for
after it. Why things are the way they are is in [docs/decisions.md](docs/decisions.md); how they got
that way is in the git history.

## Where it stands

### The engine and conformance with the web

The web app in `driftbox/` is the reference, and is not changed from here. The emitter runs its
TypeScript and writes fixtures, and the Swift is held to them:

- Documents, song plans, the pattern edits, the MIDI clock follower and the 22 drum voices'
  descriptions match exactly.
- Every voice, the 303, the sends, the master inserts (the browser's compressor included) and the
  performance filter render close to Chromium, mostly within -80 to -140dB of the peak.
  [docs/conformance.md](docs/conformance.md) gives each figure and the few exceptions.
- Whole mixes: four of eight catalogue songs match to -80 to -98dB. The other four agree in level
  to 0.3dB and differ in a few stretches, because of a channel-count effect inside Chromium's delay
  loop that is not yet understood. Chromium on x64 and on arm64 disagree on those four too.
- The rack's 48 modules compile to the reference's plans and render bit-identically, over 107
  fixture patches and every factory patch. Panels and cables match its layout to the number.
- The constrained targets (DSP, sequencing, engine, rack) have no dependencies, allocate nothing on
  the render path and build as Embedded Swift. The real-time engine is held to the offline one:
  the voices and the 303 to the bit, the whole engine within -90dB.

### The groovebox

Two 303s, an 808 and a 909, with everything the web app edits: the step grid, the 303 lines with
pitch, accent and slide, flams, the performance filter's lane, loop lengths, the song as sections
with a pattern per machine, knobs and sends per voice, and the effects. Every edit in `pattern.ts`
is ported and undoes a step at a time. Automation records from the knobs, tempo and swing. There is
a loop, a metronome and a count-in, keyboard play and 303 step entry, and vibes, the performance
mode. The catalogue's songs ship with it.

### The rack

- **Modules:** all 48 of the reference's, plus two of its own: `plugin` and `plugin-instrument`.
  The groovebox is a module too, with a strip and meter per machine and the song's arrangement.
- **The front and back:** every module has its generic faceplate, and every one the reference
  builds by hand has its own face: meters, sequencers, players, samplers and the Combinator with
  its routing inspector. Turned round, the back has bays, jacks and hanging cables, patched by
  dragging. Each inlet has a trim pot.
- **Playing it:** the typing keys, on-screen keys on a touchscreen, and MIDI while the rack is in
  front. With no MIDI module, the keys make one.
- **Samples:** read at the rack's own rate. WAV everywhere, and other formats through Core Audio on
  the Mac and the NDK's codecs on Android. The Key Atlas maps a set of recordings by their names.
  The rack's Audio Input hears live input on the Mac and Windows.
- **Plug-ins:** Audio Unit effects and instruments on the Mac, and VST 3 on Windows. Each has four
  macros, which can learn a controller or take a Combinator routing, and its state is kept in the
  patch. VST 3 modules are scanned in a separate process, so a crashing plug-in cannot take the
  app with it.
- **Guides and tours:** every module has a guide; sixteen have one written for them, and the rest
  are assembled from their definitions. Five of the reference's six guided tours run on every
  platform. The sixth needs the web rack's automation desk, which the native rack does not have.
- **As a plug-in:** on the Mac, `Driftbox: Rack` and `Driftbox: Groovebox` are AUv3 instruments.
  They follow the host's transport and song position, take its MIDI, and show their own faces.
  The groovebox exposes its knobs as parameters; the rack exposes eight learnable macros.

### Visuals

All twenty-seven of the web's scenes are ported, with Pulse as the fallback. Each keeps its id, so
a song's `visual` hint works on both platforms. On the Mac a scene is chosen from View ▸ Scene or
cycled through. On the Mac and Windows the visuals window goes full screen on any display. The shared GPU layer
(`DriftboxGPU`) runs on Metal, Direct3D 11 and OpenGL ES 3.0. The shaders are written once in GLSL
and generated for each backend, and CI checks that the generated files are current. Every scene on
the layer is held frame by frame to its Metal scene. Windows, Android and Linux draw through the
layer. The Mac app still draws through its own Metal scenes.

### MIDI

- **In:** notes from any source, chosen per source, and following an external clock's tempo,
  start, stop and position.
- **Out:** clock.
- **The rack:** a keyboard of its own on each channel, with the mod wheel, bend, pressure,
  expression, breath and sustain, and MIDI learn.
- **Platforms:** CoreMIDI on the Mac, WinMM on Windows, Android's native MIDI, and the ALSA
  sequencer on Linux. Sent messages are scheduled to their time wherever the platform's driver
  would not keep to it. Following a clock and sending one are still kept apart; see below.

### Files and export

- **Songs:** saved as `.driftbox`, which is the web app's document byte for byte. `.song.json` and
  `.json` files still open, and save back under their own names. Rack patches read and write the
  reference's format.
- **Audio:** the mix as one WAV, or a WAV per voice.
- **Movies:** File ▸ Export Movie writes the song with its scene. Record Performance keeps what was
  played and writes it as a movie, sounding exactly as it was heard. Both are on the Mac
  (AVFoundation) and Windows (Media Foundation).

### Platforms

- **Mac:** the reference app. It is a full document app, with a menu bar, recent documents,
  Settings, windows restored at launch, and the output device kept to through an unplug. The rack
  has a window of its own (⌘3), and there is a visuals window (⌘2). Built with SwiftPM and bundled
  by `scripts/bundle-app.sh`, which also builds the AUv3 extension.
- **Windows:** the same app on `Session` and `RackSession`, drawn on the GPU layer by
  `DriftboxInterface` rather than built from a toolkit. It has the groovebox, the rack, the visuals
  window, and audio and movie export. It hosts VST 3 where the Mac hosts Audio Units, and has no
  AUv3. Songs open from Explorer, and Open Recent feeds the taskbar's jump list.
- **Android:** the groovebox and rack laid out for touch, on phones and tablets. A phone shows eight
  steps a page, has a keyboard for 303 notes, and has edit and perform modes. The rack pinches and
  pans. Audio uses AAudio, with the render thread kept to the big cores, and the app keeps playing
  in the background. Files go through the storage access framework. Built without Gradle by
  `scripts/android-app.sh`, on any of the three desktop hosts; CI builds it on Linux.
- **Linux:** a desktop preview on the shared `Desktop`, using GTK 4, Pango, OpenGL ES, PipeWire and
  the ALSA sequencer. It has the groovebox and the rack, saving and opening, WAV import and export,
  device choice with recovery, and MIDI. CI builds and install-tests an archive and a `.deb` for
  arm64 and x86-64 Ubuntu 24.04. [docs/LINUX.md](docs/LINUX.md) keeps its own record.

### Accessibility

- **Windows:** everything is described to UI Automation: the groovebox, the rack's front and back,
  patching jack by jack, trims, Combinator routings, help and the tour panel. While a screen reader
  runs, Tab and the arrow keys move between controls. This is tested against Windows' own UI
  Automation client.
- **Mac:** VoiceOver uses SwiftUI's accessibility, with labels where a control needs one; the trims
  are sliders. It has not had a VoiceOver pass of its own.
- **Linux:** the shared descriptions exist, but nothing hands them to AT-SPI yet.
- **Android:** not yet described to TalkBack.

### Help

- **Groovebox and rack guides:** each is written for each platform's own controls. On the Mac they
  are under Help (⌘? and ⌥⌘?). On Windows and Linux they are under Help and on F1, drawn as a
  `HelpSheet`. On Android they are in the song's and patch's chips.
- **Module guides:** first in a module's menu everywhere.
- **Tours:** from Help ▸ Rack Tours, or the patch chip on Android. The first one is offered once.
- **Mac Help Book:** Help ▸ Driftbox Help opens an offline, indexed copy of the shared guides.
  Contextual `?` buttons open the relevant topic from the song controls, sound panels, Settings,
  rack and routing inspector. Bare SwiftPM and AU-hosted views open the same topic in a guide sheet.
- **Help tags:** the Mac's controls explain behaviour beyond their labels, including automation,
  exports, audio devices, MIDI clock, bass layers and Combinator routing ranges.
- **Learning:** practical groovebox walkthroughs cover drums, bass, arrangement and automation,
  with troubleshooting; the rack's learning path adds listening exercises to all five tours.
  The Mac's guide windows search their full text. Drawn rack tours bring each step's module into
  view below the coach, zooming it on touchscreens, without repeatedly overriding manual scrolling.

### Releases

The version is 0.1.0, build 1, in `scripts/version.env`. Nothing has been tagged or published yet.
The repository is public.

- **Mac:** `scripts/release.py` signs with a Developer ID, notarises, staples and checks with
  Gatekeeper, leaving a ZIP, checksum and manifest in `dist/`. [docs/RELEASING.md](docs/RELEASING.md)
  has the steps.
- **Windows:** a tag runs `release.yml`, which builds the programs, an Inno Setup installer and a
  zip, signs them through the SignPath Foundation, and drafts a release.
- **Android:** `scripts/android-release.py` makes an APK and an App Bundle signed with the upload
  key. The app has an adaptive icon, a fixed target SDK and optional MIDI, and leaves out the test
  loopback.
- **Linux:** `linux-package.yml` builds and install-tests the archive and the `.deb`.

## Before the first release

**(you)** marks something only the owner can do: credentials, hardware, decisions, accounts.
**(code)** marks work in the repository.

### Signing and publishing

- [ ] **(you)** Store the Mac's notary profile with
  `xcrun notarytool store-credentials "Driftbox-notary"`, then run `python3 scripts/release.py
  prepare` and try the unzipped copy as RELEASING's "Before publishing" list says.
- [ ] **(you)** Create the Android upload keystore (`keytool -genkeypair …`, in RELEASING) and keep
  it and its password safe. Then run `scripts/android-release.py prepare` and install both forms on
  a device.
- [ ] **(you)** Apply to the SignPath Foundation now that the repository is public. It signs only
  once a first release exists; winget needs a signed one.
- [ ] **(you)** Decide where each platform's release goes: GitHub Releases, Google Play or F-Droid,
  winget, and whether the Mac App Store is worth considering. RELEASING still says this is to be
  decided.
- [ ] **(code)** The project website on GitHub Pages, in progress in parallel.

### By ear and by hand

- [ ] **(you)** A listening pass across the catalogue and the factory patches, on each platform's
  own output. Include Live Wire through a real input on the Mac and Windows.
- [ ] **(you)** USB MIDI timing with a real controller: whether Android's USB driver keeps to the
  stamps, and clock drift and jitter from the ALSA sequencer on Linux.
- [ ] **(you)** Unplug a device while playing. On Android the loss of a stream is handled, but
  nobody has seen it happen. The desktops fall back to the system's output and return when the
  device does, and are worth one look each.
- [ ] **(you)** Try the Windows app with Narrator and NVDA themselves. So far it has only been
  checked against UI Automation's client.
- [ ] **(you)** Decide whether following an external clock and sending one should stay exclusive.
  The only loop left is through someone's MIDI thru, and the alternative is relaying a master
  clock on to other gear.

### Help

- [x] **(code)** A Mac Help Book with native topic search and anchors so that a `?` beside a panel
  opens its page. Generated from the shared guides and validated before signing.
- [x] **(code)** Help tags where a control's purpose is not its label: audio/MIDI settings,
  automation, exports, bass layers and routing endpoints.
- [x] **(code)** On the drawn rack (Windows, Android, Linux), have a tour step scroll or zoom its
  module into view, with room below the instruction panel.

### Linux

The first-release scope and acceptance list are in [docs/LINUX.md](docs/LINUX.md). What it still
lists as open:

- [ ] **(code)** Measured output latency and underrun reporting in the PipeWire adapter.
- [ ] **(code)** An AT-SPI adapter for the shared accessibility tree, and a decision on how much of
  it the first release needs.
- [ ] **(code)** Recheck the shell's `MainActor` integration, which uses private Swift runtime
  hooks, with each toolchain update.
- [ ] **(you)** Qualify the rest by hand: native Wayland menus (XWayland is the workaround for
  now), file-manager drag and drop and WAV import, GNOME and KDE on Wayland and X11, suspend and
  resume, and real audio, MIDI and GPU hardware.

## After the first release

- **The Mac onto the shared GPU layer.** The Mac's visuals, visuals window and movie export would
  draw through `GPUScenes` on the Metal backend and `DriftboxMovie`, and the Metal-only `Scene`
  types would be deleted. Every GPU scene is already held to its Metal one frame by frame, so this
  is a large internal change with nothing new to see. It is deferred on purpose.
- **Tutorials that play,** in the groovebox and the rack: a song or a patch built a step at a time,
  each step heard before the next, as the reference's tutorial coach does.
- **iOS.** It shares the touch design with Android: `DriftboxTouch`, the layouts and the gestures
  already live below the views. Beyond that it needs an audio session, background audio, Now
  Playing, haptics, and the AUv3 extension, which the Mac's units already are.
- **VST 3 on the Mac.** The bridge, the host and the scanner are compiled for Windows only.
- **Live input on Android and Linux,** for the rack's Audio Input module, which the Mac and Windows
  have.
- **Screen readers on Android** (TalkBack), from the same accessibility tree Windows uses.
- **Plug-ins on Linux,** hosting them and being one (VST 3, LV2 or CLAP).
- **The web rack's automation desk and performance views,** and with them the sixth tour, "Record a
  knob move".
- **Pointer history for Longhand.** The web samples the pointer at its own rate, so a fast flick
  draws a finer line there. `SceneInput` carries one touch a frame; worth changing when a second
  scene wants it.
- **More than one song open at once,** as one shared host with a song per window, when comparing
  two songs earns it.
- **The four whole mixes** that differ from Chromium in a few stretches, if the effect in its delay
  loop is ever pinned down.
