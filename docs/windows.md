# Windows

Driftbox on Windows is the shared desktop app, `DriftboxDesktop`, with Windows' parts: WASAPI and
WinMM for audio and MIDI, a Win32 window, Direct3D 11, DirectWrite, and UI Automation for screen
readers. The rack hosts VST 3 plug-ins. How the parts fit together is in
[architecture.md](architecture.md).

## Building

Swift 6.4 from swift.org, and the Visual Studio Build Tools with the C++ compiler and a Windows
SDK. Build in a shell that has run `vcvars64.bat`, with `SDKROOT` pointing at the toolchain's
`Windows.sdk`.

```bash
swift build -c release --build-tests --build-system native -Xswiftc -enable-testing
swift test -c release --skip-build --build-system native
swift build -c release --product driftbox-play
swift build -c release --product DriftboxWindows
```

Build in release, because a debug build does not link there yet: the specialisations that
`@_noAllocation` makes even at `-Onone` collide with the same ones `swiftSwiftOnoneSupport.dll`
exports. CI builds and tests the whole package this way on GitHub's Windows runners, and runs the
MIDI scheduler's tests on their own.

## Audio

WASAPI in shared mode, event driven, float stereo at 48 kHz converted to the device's format by
Windows. Everything WASAPI is made, used and released on the stream's own thread at Pro Audio
priority, so the interface's thread keeps whichever COM apartment it needs. The route follows
devices through `IMMNotificationClient` (a COM object built by hand in Swift, as nothing builds
one), and a stream whose device goes away ends and asks to be replaced.

The rack's Audio Input module hears live input through the same route.

## MIDI

WinMM, which sends at once and says nothing when devices change. So clock out goes through a
scheduler of its own that holds each message to its stamp on a high-resolution timer, to within a
millisecond (`MIDIQueue`, shared with Android), and devices are read again every two seconds and
known by name. A clock for another program on the same machine goes through a loopback port made
in Windows MIDI Services.

## The window

`DriftboxWin32` answers `DriftboxShell`. While a window is dragged or resized Windows runs a loop
of its own and the app's stops, so the window draws a frame from a timer and on every change of
size until the drag ends, and the picture follows the edge instead of freezing.

Its loop is the only one on its thread. Foundation's run loop, turned as well, took the window's
key messages before its shortcuts could, which is how Space once came to play nothing. So work
from other threads, such as an audio device's change, comes through `post`, onto the window's own
queue.

## The app

`DriftboxWindows` is a window with the song's scene filling it, and the controls over it: the
transport bar, the song as a strip of sections to play from, the step grid and its patterns, and
the selected voice's knobs or the song's effects. The rest of the window is the performance
filter's pad, and menus hold the rest. Tab hides the controls, to perform. The keyboard is an
instrument, as on the Mac: the number row strikes the drums, the home row plays 303 A, `z` and `x`
its octave.

The rack is there too, from Rack ▸ Show Rack (Ctrl+R): the patch's modules with their knobs and
choices, its catalogue of patches, the back with its cables, and the keys playing it, heard beside
the groovebox. A MIDI keyboard plays it.

- **File:** New, Open…, Open Recent (the ten songs opened or saved lately, which the taskbar's jump
  list shows too), the catalogue, Save and Save As… as `.driftbox`. Export Mix… as one WAV, and
  Export Stems… as a WAV for each voice the song uses, in a folder chosen in Windows' own panel.
  Export Movie…, the song and its visuals as an H.264 and AAC `.mp4`, and Record Performance, what
  is played written as one. Each is written while the app carries on, with progress in the title,
  then shown in Explorer.
- **Edit:** Undo and Redo, named for the edit.
- **Transport:** play and stop, sections, the loop set to a section or cleared whatever it spans,
  the metronome and the count-in.
- **View:** the controls shown or hidden, and the song's scene or any other; and the visuals in a
  window of their own (Ctrl+2), or full screen on a display chosen by name, for a projector.
  Escape, F11 or a double-click leave full screen, Space plays and stops, the pointer hides when
  still, and the window comes back where it was at the next launch.
- **Audio and MIDI:** the output device, the MIDI inputs heard, and the MIDI clock followed or
  sent, and where. Settings are menu items the menu ticks as it opens.

Closing, opening or starting afresh over unsaved work asks first, in Windows' own words.

The executable only chooses Windows' parts and hands them to `DriftboxDesktop`, the app every
platform with a `ShellWindow` runs, on `Session`. `DesktopTests` hold that app to its menus,
commands, title, care over unsaved work and frames, with a stand-in window, on WARP.

## Help

Help ▸ Groovebox Guide and Rack Guide, and F1 for the one showing, draw the guide over the window:
`DriftboxHelp`'s words for Windows, saying what the drawn app's own chips, right-click menus, menu
bar and keys do, a tab for each topic, scrolled by the wheel and the keys and put away with Esc. A
module's own guide is the first item in its menu. `HelpSheet` lays them out on the canvas, and
Android shows the same pages.

Help ▸ Rack Tours starts a guided tour of the rack, and the rack offers the first once. The tour's
panel is painted in the rack's corner, its buttons read by a screen reader, with a ring round the
chip or module the step names.

## Screen readers

The controls are drawn, not windows of their own, so the app describes them to Windows' UI
Automation itself, as Narrator and NVDA read it (`CAccessibility`, a provider in C++ fed the tree
the app describes). Nothing is described until something reads the window.

- **The groovebox:** the transport, the tempo and swing, the song's sections and patterns, every
  lane's steps, each 303 step's note, accent and slide, and the knobs showing, each by a name a
  person would give it and with what it is set to in words. A screen reader presses a button,
  turns a step over or sets a knob, and the app does it as a hand would.
- **The rack:** its transport, tempo and Add; each module a group of its knobs, choices, buttons
  and numbers, named as its face names them with its abbreviations said whole, a mute or a gate
  said as on or off, and each module's menu a button.
- **The rack's back:** each module's jacks say what they are patched to, and a screen reader
  patches as a hand does: press a jack to take a cable from it and one of the other kind to plug
  it in, pull a cable out of an inlet, and turn an inlet's trim. A Combinator's routing is
  described and edited too: each routing's source, module and knob offer the menus a click does,
  and its two ends are sliders.
- **The guides** are read as the controls are.

While a screen reader runs, as Windows says one is, the keyboard moves between the controls as in
any Windows program: Tab and Shift+Tab to the next and the one before, Enter to press it, and the
arrows to turn a knob or a number a notch. The screen reader hears where it is, and a ring shows
it. Space still plays and stops, and Show Controls and Show Back stay in the View menu, without
Tab.

## VST 3 plug-ins

The rack's `plugin` module hosts VST 3 plug-ins, on Steinberg's SDK, vendored in `Sources/VST3SDK`.
`CVST3` is the bridge in C; `DriftboxHostVST3` finds the plug-ins installed and plays each as a
module's unit, with its macros and its state; and `DriftboxVST3Scan` asks each module what it
holds in a process of its own, so a plug-in that crashes as it loads takes the scanner with it
rather than the app. `Tests/DriftboxVST3Fixture` is a plug-in of the project's own to test the
bridge against, and `Tests/DriftboxVST3Crash` one that crashes as it loads, for the scanner.

## Movies

`DriftboxMovie` plays a take again on an engine of its own, draws each frame offscreen on the GPU
layer and reads it back, and hands it with its sound to `CMovieWriter`: an H.264 and AAC MPEG-4
file through Media Foundation's sink writer, and a movie read back through its source reader, for
the tests.

## Shipping

The program carries Driftbox's icon, which `scripts/windows-icon.mjs` draws from the web app's own
icon in a Chromium: the four-pad picture at 16 to 32 pixels, the full one from 48 up. It and the
plug-in scanner carry their version too, as Explorer shows it and signing checks it, in
`windows/Driftbox.res` and `windows/DriftboxVST3Scan.res`. `scripts/windows-resources.mjs` writes
those from `scripts/version.env` and compiles them with the SDK's `rc`: run it again after changing
the version.

It opens a song it is handed, as Explorer hands one over. `DriftboxWindows.exe --register` makes
`.driftbox` files open in it and show its icon, for the current user, as an installer would;
`--unregister` gives them back.

After a release build,

```bash
node scripts/windows-package.mjs
```

makes `dist/Driftbox`, which runs on a machine with no Swift on it, and a zip of it: the program,
the plug-in scanner beside it, the catalogue's resource bundle, and the Swift and Visual C++
runtime DLLs it loads, found by reading their import tables. That is 18 DLLs, about 86MB, 30MB
zipped.

With Inno Setup 6 installed (`winget install JRSoftware.InnoSetup`),

```bash
node scripts/windows-installer.mjs
```

packages it and makes `dist/Driftbox-<version>-setup-x64.exe` from `windows/Driftbox.iss`, about
22MB. It installs for the person running it, with no administrator needed unless they choose
everyone; puts Driftbox in the Start menu; makes `.driftbox` songs open in it if they want that,
writing the keys `--register` writes; and takes all of it away again on uninstalling. One made
locally is not signed, so Windows warns before it runs.

## Releasing

Pushing a tag `v<version>`, matching `scripts/version.env`, runs
[`.github/workflows/release.yml`](../.github/workflows/release.yml) on GitHub's Windows runners. It
builds, packages, makes the installer and drafts a release with it and the zip.

Signing is free for open source through the SignPath Foundation, as
[CODE_SIGNING.md](../CODE_SIGNING.md) sets out. Once the repository has the
`SIGNPATH_ORGANIZATION_ID` variable and the `SIGNPATH_API_TOKEN` secret, the workflow has the
programs signed, builds the installer from them, and has that signed too, each request approved by
hand in SignPath. Until then everything is built unsigned. `.signpath/artifact-configurations`
holds what SignPath is to be told to sign.

What the render costs on Windows is in [performance.md](performance.md).
