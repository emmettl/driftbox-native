# The Mac

The Mac app is SwiftUI over the shared sessions, with Core Audio, Core MIDI and Audio Units
underneath and the visuals drawn in Metal. It is the platform the port started on, and the one the
others follow. How the parts fit together is in [architecture.md](architecture.md).

## Building and running

Swift 6.4 and macOS 26. Xcode's toolchain builds and tests the package; `scripts/check-constrained.sh`
also needs a swift.org toolchain for its Embedded half (see
[architecture.md](architecture.md#the-constrained-targets)).

```bash
scripts/bundle-app.sh && open .build-release/Driftbox.app
```

The app is a SwiftPM executable rather than an Xcode project. `scripts/bundle-app.sh` builds it in
release and wraps it in an application bundle, so that the system treats it as an app (a Dock
icon, activation, a bundle identifier), with the rack and the groovebox inside it as an AUv3
extension for other apps to load. It puts every target's resource bundle (the app's, the session's
songs, the rack session's patches and cards) in `Contents/Resources`, where `Bundle.module` looks
first, and signs the result ad hoc, for this machine.

`swift run Driftbox` also works, for a quick look: the executable announces itself to the system by
hand on launch, since without a bundle there would be no window and no menu, and it finds its
resources at their build paths.

## The app

- **The groovebox:** the catalogue as a library, a transport, the step and 303 grids of the
  pattern the transport is in, live and editable, the voice and effects panels, and the
  performance pad.
- **Files:** open, save and Save As as `.driftbox`, recent documents, the window's title, proxy
  icon and edited dot, a prompt before replacing unsaved work, and songs dropped on the window or
  opened from the Finder. Export Mix, Export Stems and Export Movie, and Record Performance, which
  keeps what is played as a take and writes it as a movie.
- **MIDI:** in from the sources chosen in Settings, per source and live as devices come and go, and
  clock out to where Settings says.
- **Settings** (⌘,): the MIDI sources, the clock, the output device (kept to: an interface that is
  unplugged plays through the system's device until it is back, and says so), and whether the
  visuals run.
- **The visuals**, in a pane and in a window of their own (⌘2) that goes full screen on a named
  display from View ▸ Visuals Full Screen On. One renderer draws each frame once and every view
  shows it, so the pane previews exactly what the window is showing. See [visuals.md](visuals.md).
- **The rack** (⌘3), in a window of its own: the patch's modules, their faces and backs, the
  cables, the keys, the catalogue of patches, the controllers learnt onto it, and the Audio Input
  module hearing live input.
- **Help:** Help ▸ Driftbox Help opens the searchable, offline system Help Book. The song controls,
  sound panels, Settings, rack and routing inspector have `?` buttons to open their topic.
  Help ▸ Groovebox Guide (⌘?) and Rack Guide (⌥⌘?) remain windows of their own; a
  module's guide, first in its menu, as a sheet over the rack; and Help ▸ Rack Tours, guided tours
  of the rack whose panel sits in the rack's corner, the control a step names breathing a ring.

Both guide windows have a search field that finds matching sections in headings, instructions,
control descriptions and notes. The groovebox's Walkthroughs topic builds a drum variation, a
303 phrase, a two-section arrangement and a recorded filter sweep, with listening checks and a
Troubleshooting topic. The rack's Learning path explains the five tours, gives a listening exercise
after each, and explains how to recover when a step does not complete. The same lessons are in
the drawn guides, using each platform's controls; automation recording requires the tablet layout
on Android.

`scripts/bundle-app.sh` generates `Contents/Resources/Driftbox.help` from `DriftboxHelp` and
builds its native search index with `hiutil`. There is no separate copy of the guide text to edit.
To rebuild and validate just the book, run `scripts/build-help-book.sh`; the default output is
`.build-release/Driftbox.help`. The validator checks local links, named anchors and indexed pages.
The app's Info.plist registers the book. A bare `swift run Driftbox` or an AU host has no registered
book of its own, so contextual help opens the matching topic in a guide sheet instead.

The song and the visuals window come back where they were at the next launch.

## Audio Units

**Hosted.** The rack's `plugin` module hosts Audio Unit effects, and its `plugin-instrument`
module instruments, played by MIDI made from the rack's notes. `HostedAudioUnit` readies a unit in
stereo at the rack's rate and renders it on the rack's thread
through its own render block, with the rack's tempo, beat and transport for a unit that keeps
time. A patch keeps the unit's component and its document state, whether or not the machine
opening it has the unit, and a missing unit is silent. VST 3 hosting is on Windows only so far
(see [windows.md](windows.md#vst-3-plug-ins)).

**Exported.** The rack and the groovebox are AUv3 instruments that any Audio Unit host can load,
from the app extension `DriftboxAudioUnits`. `DriftboxExtensions` holds them: a `RackSession` and
a `Session` behind their Audio Units, made at the host's rate, with their presets, their state,
their MIDI, the host's clock and their parameters (the groovebox's knobs, the rack's eight learnt
macros), and their faces (the rack window, and the groovebox's editor) on the same sessions. A host
registers them when the app first launches.

## Releases

A release is Developer ID-signed and notarised on this Mac by `scripts/release.py`, which leaves a
stapled app, zipped, with its checksum and a manifest, in `dist/` for review, and tags, uploads and
publishes nothing. [RELEASING.md](RELEASING.md) has the one-time setup and the steps.

CI has no Mac runner: the Mac's tests run locally, and `release.py prepare` runs the whole suite
strictly before it signs anything.
