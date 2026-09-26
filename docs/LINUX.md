# Linux port

Linux has two independent tracks: a development machine and a native application. A VM that
builds the shared code is useful progress, but does not establish that the desktop port works.

## Scope of the first release

A standalone ARM64 and x86-64 desktop application using the existing `Desktop`, `Session`,
`RackSession`, instrument engines, document codecs and canvas interface. It should play and edit
songs, run the built-in rack, save/reopen documents, import WAV samples, export audio, and exchange
MIDI notes and clock. Linux plug-in hosting and publishing Driftbox as a plug-in are later work.

Target Ubuntu 24.04 LTS first. Test both Wayland and X11 before claiming support for either.
PipeWire powers both the command-line player and the first shared desktop executable. GTK 4/Pango
provide its shell/text adapters and GLES the renderer. ALSA sequencer supplies the native MIDI backend.
The desktop now renders the existing groovebox and rack and passes a live audio capture test;
a relocatable preview now packages its runtime and resources. Interactive shell qualification and
fresh-machine release validation remain. Do not introduce a second UI or engine.

## What already exists

- The shared Swift targets and conformance tests build on Linux in `.github/workflows/ci.yml`.
- `DriftboxGPUGLES` runs GPU contract tests on Mesa with `EGL_PLATFORM=surfaceless`.
- `driftbox-render` renders WAV offline; `driftbox-play --bench` measures the engine without a device.
- `AudioRouting`, `RenderSource`, `Mixer`, MIDI ports and `HostTime` separate hardware from music.
- `Desktop` already accepts a shell, GPU device/surface, typesetter and sessions.
- `SessionMemory`, `RackMemory`, `SampleDecoding` and `RackPluginHosting` are existing extension points.

## Architecture work

### Preserve the constrained core

DSP, sequencing, engine and rack stay platform-independent. Linux-specific libraries belong in
adapters, selected by the executable and conditional SwiftPM dependencies. Preserve Embedded
Swift and allocation checks. Compare audio with the existing fixtures, not a new Linux reference.

### Prove event-loop and concurrency integration

`Desktop.run()` delegates the loop to `ShellWindow.run(frame:)`. The shell contract now permits
both swap-chain pacing and toolkit-scheduled render callbacks. GTK supplies the frame clock;
`GTKSurface.present()` copies into its framebuffer without swapping or owning the context. The
window experiment validates suspension while hidden and continued Swift task execution.

The loop must also run Swift `MainActor` tasks: sample-loading completions, delayed saves and
plug-in operations. `post` alone does not prove that arbitrary Swift tasks resume. Windows uses
explicit libdispatch integration; do not assume that GTK callbacks automatically supply this.
A small experiment must prove actor isolation and background-to-main completion before shipping.

### Allow toolkit-owned graphics contexts

`GLESDevice` creates an EGL display/context and offscreen pbuffer. It first requests window and
pbuffer support, then falls back to pbuffer-only for Mesa's surfaceless configurations. `GLESSurface`
is Android-only and assumes framebuffer zero for the window. GTK's GLArea supplies its own current
context and framebuffer through the borrowed-context path; the headless EGL path remains for tests. Verify orientation, alpha, resize, context loss,
resource lifetime, frame pacing and fractional display scale. No new shader language is needed.

### Make document interactions asynchronous

The shared shell now has completion-based file, save-question and context-menu requests.
`Desktop` uses them throughout open/save/close and rack sample loading. Windows keeps its existing
synchronous implementation through default completion wrappers. GTK uses response callbacks with
no nested event loop. Regression tests cover cancellation, save failure, repeated close requests
and gesture release while a dialog is pending. Native dialog interaction still needs manual
qualification. Validate desktop file portals for the eventual distribution package.

### Complete input semantics

`KeyEvent` currently serves both shortcuts/instrument keys and text. Add committed text and
composition where editing needs them, and focus-loss handling that releases held notes and
pointer gestures. Retain point-based input and explicit pixel scale. Main now supplies shared
semantic descriptions, actions and focus navigation for canvas controls.
GTK still needs an adapter that exposes those controls to Linux assistive technology; a GTK window
alone does not make the canvas accessible. Identify the first-release accessibility scope explicitly.

### Keep audio and MIDI adaptation local

Implement `DriftboxHostLinux` behind the existing ports. The audio callback must use preallocated
buffers and C-compatible render callbacks, without allocation, locks or actor work. Honour
`Mixer.rendering`/`buffers` and the guarantee that detach returns only after use of the source ends.
Handle variable buffer sizes, rate conversion, server/device loss and reconnect. Expose failures
instead of presenting a working route when the stream is not running. Stable device identifiers
must survive reconnects; PipeWire's transient numeric object IDs are not persistent preferences.

ALSA MIDI now handles source changes, virtual ports and scheduled output on `HostTime` through
a dedicated worker. Input currently uses receive-time stamps. Validate clock drift and jitter
against physical equipment before treating the backend as performance-qualified.

### Persistence and distribution

Use the existing memory ports with Linux configuration/data locations. Keep settings, cache and
user documents separate. Package SwiftPM resource bundles and the required runtime libraries;
choose a supported distribution baseline and verify a clean install without a compiler present.
Desktop entries, icons, MIME associations and file-open arguments are part of the application.
Additional sample codecs and Linux VST3/LV2/CLAP integration are follow-on scope, not prerequisites
for the built-in rack. Current VST3 loading is Windows-specific.

## Milestones and acceptance

1. **Linux development baseline.** VM on external storage; SSH; Swift matching Package.swift;
   build/test scripts; shared tests and an offline render verified inside Linux. Record the actual
   GPU renderer. A software renderer is sufficient for correctness, not a performance claim.
2. **Audible command-line player.** PipeWire output for `driftbox-play`; measured nonzero rendered
   frames, controlled stop and teardown, errors without a server. Capture output to verify it.
   Initially system-default output only if clearly documented; device selection/recovery follows.
3. **Shell experiment.** One existing scene and correctly shaped text in a real Linux window.
   Prove GTK/GLES ownership, scale, input, frame scheduling and Swift concurrency together.
4. **Shared desktop connected.** Groovebox and built-in rack through `Desktop`; asynchronous
   document operations; settings; drag/drop; keyboard focus and editing. Recheck Windows adapters.
5. **Audio/MIDI completion.** Device choice and reconnect, MIDI in/out/clock, virtual ports,
   suspend/resume, rate changes and unavailable-service behaviour.
6. **Viable release.** Clean installation on ARM64/x86-64, GNOME/KDE and Wayland/X11 checks,
   hardware audio/MIDI and Intel/AMD/NVIDIA graphics checks, documented limitations, packaging.

## Development environment

The first local VM is named **Driftbox Linux**, hosted by UTM with QEMU/HVF ARM64 virtualization,
8 GiB RAM and four virtual CPUs. The bundle is stored at
`/Volumes/StudioData/Virtual Machines/Driftbox Linux.utm`. The Ubuntu image and setup seed are
under `Virtual Machines/Downloads` on the same volume. Keep the volume mounted while running.

A dedicated SSH key is local machine state and must never enter this repository. The guest has
its own development account and toolchain. Do not share the host's home directory or credentials.
Build inside the guest filesystem so dependency files and build caches stay on the external disk.

The initial image is Canonical's Ubuntu 24.04 ARM64 cloud image, SHA-256:
`7b682958a67ff5de068e36de6af8b75fa645d296af5a70d6500527f6a33781db`.
A cloud-init seed creates the development account with key-only SSH. Desktop packages are installed
inside that guest after first boot. This avoids depending on an interactive OS installation.

Provision the Ubuntu guest with `scripts/linux-bootstrap.sh`. It installs the system dependencies
and Swift 6.4.0 into a user-owned directory after checking the official release signature. On the first install GPG reported a good signature
from the Swift 6.x release key, but also marked that key expired in the official key bundle;
retain that distinction when assessing the installation record.

To add the graphical development desktop to a minimal cloud guest:

```sh
sudo apt-get install --no-install-recommends ubuntu-desktop-minimal gnome-terminal spice-vdagent
# The cloud kernel omits the emulated HDA sound-card driver.
sudo apt-get install --no-install-recommends "linux-modules-extra-$(uname -r)" rtkit
sudo modprobe snd_hda_intel
sudo usermod -aG render "$USER"
sudo systemctl set-default graphical.target
sudo systemctl start gdm3
```

Reconnect SSH after changing groups so the account can use the virtual GPU render node.
Choose a desktop password with `sudo passwd "$USER"`; the bootstrap deliberately does not set one.
After kernel upgrades, install the matching `linux-modules-extra` package again, or use Ubuntu's
`linux-image-generic` metapackage to track the complete kernel and modules together.

Run `scripts/linux-build.sh doctor`, `build`, `gpu`, `test`, `window`, `desktop`, `play`, `bench`, or `render` **inside Linux**.
`gpu` invokes `driftbox-play --gpu-info`, reports the actual GLES renderer and verifies a red
render target reads back as BGRA. It does not claim window or hardware-acceleration support.
Use `DRIFTBOX_BUILD_JOBS=4` initially. The script leaves macOS/Windows builds untouched and keeps
its build products in `.build-linux`. `test` uses Mesa software rendering and strict actor checks;
large browser-generated fixtures remain the CI job's responsibility unless generated separately.

VM audio latency, virtual GPU speed and VM MIDI observations are not hardware qualification.
Shut the guest down to release RAM; merely pausing it need not release memory.

## Sources

- [UTM external storage](https://docs.getutm.app/basics/actions/)
- [UTM scripting](https://docs.getutm.app/scripting/reference/)
- [Ubuntu cloud images](https://cloud-images.ubuntu.com/noble/)
- [GTK GLArea context and framebuffer](https://docs.gtk.org/gtk4/class.GLArea.html)
- [Swift Linux run-loop wakeup integration](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFRunLoop.c)
- [GTK asynchronous file dialogs](https://docs.gtk.org/gtk4/class.FileDialog.html)
- [PipeWire stream API](https://docs.pipewire.org/group__pw__stream.html)
- [ALSA sequencer API](https://alsa-project.org/alsa-doc/alsa-lib/seq.html)

## Initial implementation status

The worktree has the roadmap, Ubuntu bootstrap, Linux build commands and a GLES diagnostic in
`driftbox-play`. UTM and the verified Ubuntu image are installed on the host; the VM has been
moved to StudioData and booted successfully. Ubuntu 24.04.5 reports ARM64 and four CPUs;
cloud-init completed with no errors, and SSH plus the QEMU guest agent are working. The worktree
has been copied into `/home/driftbox/driftbox-native`, and shell syntax checks pass inside Linux.

The disk has been expanded to 50 GiB and Ubuntu automatically grew the root filesystem to about
48 GiB usable (about 40 GiB free after installing the toolchain and desktop). A SHA-256-verified
backup of the original imported disk is under `Virtual Machines/Backups` on StudioData.
Ubuntu's minimal GNOME desktop and GDM are installed; the user has set a password and signed in.
Swift 6.4.0, Mesa, GTK/Pango, PipeWire and ALSA development dependencies are installed.

Both `driftbox-render` and `driftbox-play` build inside Ubuntu ARM64. An offline render of
`acid.song.json` was verified as 96,000 stereo frames at 48 kHz: all samples finite, peak 0.6484,
with nonzero output. The initial GPU diagnostic exposed an EGL config error: a surfaceless
display cannot supply the requested window bit. Linux now requests a pbuffer-only configuration;
Android retains its existing window/pbuffer configuration.

Validation in Ubuntu ARM64:

- The initial full suite reported 502 tests, with 13 generated-fixture tests skipped. All failures
  were EGL configuration errors in GPU, canvas, shared desktop and touch tests. After the fix,
  targeted reruns covering every failing test passed (69 tests including related layout checks).
  The unaffected suites passed in the original run. A full suite after the fix has not been rerun.
- The software path reports `llvmpipe (LLVM 20.1.2, 128 bits)`, OpenGL ES 3.2 / Mesa 25.2.8.
- The default VM path reports `virgl (ANGLE (Apple, Apple M4 Max, OpenGL 4.1 Metal - 91.7))`,
  OpenGL ES 3.0 / Mesa 25.2.8. Both pass the diagnostic's BGRA clear/readback check. This establishes
  working offscreen graphics; it does not qualify window presentation, latency or native GPU speed.
- Guest logs are `~/driftbox-linux-{tests,gpu,gpu-tests,desktop-tests}.log`; the verified audio file
  is `~/driftbox-linux-smoke.wav`.

The signed-in session runs PipeWire, WirePlumber and RTKit. Installing the missing HDA kernel
module replaced Dummy Output with Built-in Audio Analog Stereo. `pw-play` successfully sent the
two-second offline render to that output; audible playback at the Mac speakers is not independently
confirmed. The native PipeWire command-line adapter described below is now implemented; the Linux
desktop shell is connected in the preview described below.

macOS `driftbox-play` also builds successfully with its scratch directory on StudioData.
Swift formatting, shell syntax and `git diff --check` pass; both provisioning/build scripts refuse
to run on macOS. The existing Linux CI job now invokes `--gpu-info`; remote CI has not run yet.

## Live command-line audio

`DriftboxHostLinux.PipeWireOutput` now plays the existing `Mixer` and `RenderSource` through
PipeWire's default output. Run these commands **inside the signed-in Linux guest**:

```sh
cd ~/driftbox-native
scripts/linux-build.sh play conformance/fixtures/documents/acid.song.json --seconds 10
# Omit --seconds to play until Ctrl-C; --start-bar and the existing --bench also work.
```

The player renders stereo float audio at 48 kHz; PipeWire handles conversion to the graph/device
rate. The C bridge negotiates the stream and interleaves preallocated planar buffers. It splits
large callback requests into at most 4096-frame chunks. The realtime callback performs no explicit
allocation, logging, locking or actor dispatch. Its Swift entry point is outside the main actor;
strict executor checks stay enabled during validation. Only control operations use the main actor.

Before changing mixer sources, a lock-free atomic gate disables rendering and the control thread
waits for any source callback already in flight. This keeps owners alive until detach is safe,
even if the graph has stopped requesting buffers. Destruction stops the PipeWire loop and destroys
the stream before releasing callback storage. A source with a different rate is rejected.

Startup requires a streaming output within five seconds. A disconnected stream or three seconds
without rendering produces a diagnostic and nonzero exit. Duration expiry, Ctrl-C and SIGTERM
perform orderly teardown. This is a CLI baseline, not yet the full `AudioRouting` adapter: device
listing/selection, automatic recovery, measured output latency and underrun reporting are pending.
The desktop now uses the device-aware `AudioRouting` adapter described below. Native MIDI is also
implemented below. The preview packaging is described below; the rack uses its existing WAV decoder.

### Audio validation

```sh
DRIFTBOX_TEST_PIPEWIRE=1 scripts/linux-build.sh test --filter PipeWireTests
python3 scripts/test-linux-play.py .build-linux/release/driftbox-play
```

The integration tests opt in because they need an active PipeWire session. Four passed under strict
Swift actor isolation: invalid-rate rejection, detach/reattach/stop, source-owner lifetime with
stream reopening, and detach while a test callback is deliberately still running. The test source
can emit a brief constant signal; use a development output. Without the opt-in, the three live tests
are skipped and the invalid-rate test still runs in CI.

The Python smoke test creates an unconnected recorder (`--target=0`) and links only its child
player's output ports, identified by client PID. It never links a microphone. The capture contained
146,432 stereo frames at 48 kHz, finite samples and peaks of 0.67445 on both channels. The player
rendered 144,384 frames before stopping; the recorder also includes boundary silence. Both stop
signals passed, as did removal of the player's own stream, a nonexistent server and invalid
duration arguments. Missing-server and lost-stream cases exited 1 without a crash. Logs are
`~/driftbox-pipewire-{build,tests,smoke}.log`. The Mac player build also passed.

These checks verify live rendering and safe ownership in this ARM64 VM. They do not establish
physical speaker output, sustained glitch-free playback, measured latency, x86-64 behavior or
real-device hotplug recovery. The shell/context/concurrency experiment below is implemented
separately, while audio device management can build on this stream implementation.

## Linux window experiment

`driftbox-linux-window` draws the existing Graphic Lab scene through GLES and the shared Canvas,
with Pango shaping and Cairo glyph coverage. This is a silent graphics/input experiment with
synthetic music levels. It remains a separate diagnostic; `driftbox-linux`, described below,
connects the shared desktop, documents and live audio.
Run from a terminal in the Linux desktop:

```sh
scripts/linux-build.sh window
# Drag to choose a Graphic Lab edition, Space to pause, Escape to close.
scripts/linux-build.sh window --self-test
```

`--seconds N` closes after a bounded run and requires rendering and Swift async completion.
`--self-test` additionally requests an 800 × 500 window, hides it, confirms frame callbacks stop
while MainActor tasks continue, shows it again and checks that drawing resumes. It exits after
six seconds with a nonzero result on failure. Use a normal, unmaximized window for this test.

GTK owns the GLES context, render framebuffer and frame clock. `GLESDevice` now has an explicit
borrowed-context initializer; the original EGL/pbuffer path remains for headless tests. Each frame
captures GTK's framebuffer and pixel viewport before drawing; a final vertically flipped blit
presents the shared renderer's top-down target. Resource teardown happens during GLArea unrealize
with its context current. The pixel-to-logical-width ratio determines Canvas text scale. Pointer
release, gesture cancellation and focus loss clear the active gesture.

The GLib loop watches libdispatch's main-queue eventfd. It acknowledges the wakeup before invoking
`_dispatch_main_queue_callback_4CF`, matching CoreFoundation's Linux behavior; failing to acknowledge
it starves GTK frame sources. There is no periodic queue polling. These underscored symbols are
**private Swift runtime ABI**, tested with Swift 6.4.0, not a stable public GTK integration API.
Revalidate the bridge on every toolchain update. Do not run a competing CFRunLoop consumer of the
same main-queue handle, and introduce one process-wide bridge before supporting multiple windows.

Pango retains the exact fallback font for each glyph run. Cairo supplies grayscale glyph coverage
to the shared atlas, including fractional horizontal placement. Missing-glyph identifiers that
exceed the shared UInt16 index are retained through a separate face entry. Colour emoji and IME
composition are not implemented by this typesetter.

### Window validation

The Ubuntu ARM64 run passed 48 focused Pango, GPU, Canvas, presentation and layout tests. Pango
checks cover combining marks, trailing spaces, Arabic/fallback shaping, missing-glyph coverage,
baselines and fractional placement. The C bridges pass `-Wall -Wextra -Werror`. The Mac player
build still passes.

The Xvfb/llvmpipe lifecycle run rendered 302 frames with strict Swift actor checking. It resized,
suspended rendering while hidden, ran delayed and background-to-MainActor work, resumed drawing
and exited cleanly. A second run at 2× scale rendered 202 frames, using 2000 × 1440 pixels before
resizing to 1600 × 1200; all lifecycle checks passed. That run used an Xvfb screen of 2560 × 1920
to accommodate the logical window size. Invalid durations and an unavailable display also failed
cleanly with exit 1.

After unlocking GNOME, visual inspection confirmed upright Latin/Arabic text, animated Graphic Lab
editions and the translucent overlay on the virtual GPU. Both native Wayland and X11 through
XWayland passed the lifecycle test with strict actor checks: 1,206 and 1,361 frames respectively,
including resize, stopped rendering while hidden, async completion, resumed drawing and shutdown.
Both report virgl/ANGLE through the Apple M4 Max. This is VM graphics validation, not physical Linux
hardware qualification or an Xorg-session test.

The demo now starts at 900 × 600 so it fits the VM desktop without GNOME automatically maximizing
it. The self-test requests 800 × 500 and accounts for GTK's title bar: Wayland supplies an
800 × 463 drawing area, while XWayland supplies 800 × 500. The earlier assertion incorrectly
required the full outer height to be drawable. Interactive pointer/keyboard checks remain pending:
computer-control input through UTM was not reliably delivered, so a manual check was requested.

Guest logs are `~/driftbox-window-{build,tests,xvfb,scale,wayland-unlocked,xwayland,xvfb-final}.log`
and `~/driftbox-pango-tests.log`. The original 1×/2× Xvfb runs above used the earlier larger window
sizes; the revised self-test also passes the Xvfb path.

For a headless development or CI run:

```sh
sudo apt-get install --no-install-recommends xvfb xauth
xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
  SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6 \
  scripts/linux-build.sh window --self-test
```

CI now includes this lifecycle check; remote CI has not run yet. Remaining shell acceptance covers
pointer and key interaction, fractional/multi-monitor scale, compositor
minimize/restore, context recreation/loss, and sustained frame pacing on real graphics drivers.
The `GTKWindow` adapter below now feeds `Desktop` through callbacks. Keep this smaller experiment
as a diagnostic for context, scaling and event-loop changes.

## Shared desktop preview

`driftbox-linux` connects the existing groovebox and built-in rack to `GTKWindow`, `GTKSurface`,
Pango and `PipeWireRoute`. Run it from the signed-in Linux desktop:

```sh
scripts/linux-build.sh desktop
scripts/linux-build.sh desktop conformance/fixtures/documents/acid.song.json
# Ubuntu VM workaround for the native Wayland menu issue documented below:
GDK_BACKEND=x11 EGL_PLATFORM=x11 scripts/linux-build.sh desktop
# For graphics work without an audio service:
scripts/linux-build.sh desktop --silent
```

The native menu bar exposes the shared app commands and keyboard shortcuts. File choosers, save
confirmation and context menus complete through callbacks; the GLib loop and rendering continue.
GTK 4.8-compatible `GtkFileChooserNative` and response-based message dialogs keep the Debian
Bookworm CI baseline supported. Document requests are serialized and reject new editing input
while allowing resize and release/cancel events. Cancelling Open preserves the current song;
closing after a failed save keeps the window and edits. GTK owns the GL context until the desktop
and its GPU resources have been released.

`PipeWireRoute` mixes the groovebox and rack at 48 kHz using the existing PipeWire bridge.
The Audio menu lists discovered sinks and remembers a choice by `node.name`, never a transient
PipeWire object ID. With no choice it follows `default.audio.sink` metadata. If the chosen sink
is removed, it falls back to the system default while retaining the choice, then returns when
that name reappears. A profile change that changes the node name represents a different choice.
The adapter reads registry and metadata events on a separate PipeWire loop and takes synchronized
snapshots on the main actor every 250 ms. It does not write system audio preferences.

Desktop stream negotiation is asynchronous. A failed stream or server connection retries after
two seconds, preserving attached source owners; detach still waits for any in-flight callback
before releasing an owner. Discovery/stream startup has a five-second deadline, and an output
with attached sources but no rendered frames for three seconds is reopened. No sources means
intentional silence, not a stalled render callback. Explicit stop cancels recovery and releases
sources. The command-line player retains its bounded synchronous startup and failure exit behavior.
Measured latency and underrun reporting remain unimplemented. `--silent` supplies no audio route.

Normal runs use Foundation `UserDefaults` with the `org.driftbox.linux` suite for existing session
and rack memory; smoke tests do not restore or write preferences. File arguments open a song.
XDG configuration/data layout and installed-resource discovery still need release qualification.
The ALSA MIDI backend below supplies both shared MIDI ports; Linux plug-in hosting remains absent.
GTK file drops now feed the shared song-open
and rack WAV-import paths with logical-point coordinates. The bridge accepts local files, preserves
escaped names and ordering, and rejects drops while a native request is pending. File choosers
remember the last accepted folder for the lifetime of the window. IME composition, canvas
accessibility, physical keyboard/trackpad behavior and fractional/multi-monitor scaling remain
pending. WAV import is connected to the rack's shared file request path but has not had a native
dialog test; external file-manager drag/drop also still needs interactive qualification.

### Audio device and recovery validation

```sh
# Ubuntu 24.04 / WirePlumber 0.4: separate server, hardware monitors disabled.
python3 scripts/test-linux-route.py
# Optional tests against the signed-in session (temporary silent sinks only):
DRIFTBOX_TEST_PIPEWIRE=1 scripts/linux-build.sh test --filter PipeWireRouteTests
```

The private harness uses temporary runtime, configuration and state directories, a private D-Bus
session and silent virtual sinks. It restarts only the server it launched. Its four route tests
cover selection, fallback and return by name, actual graph links, stream destruction, full server
restart, default-output changes, ownership across reconnect and detach during an outage. The two
cases that change server state or default metadata run only under that harness. The ordinary
session opt-in creates/removes its own silent sinks and stream, without changing system settings.
The original four `PipeWireTests` cover the realtime gate and source lifetime at the output layer.

All four route tests passed on Ubuntu ARM64 with strict actor checks; the original four output
integration tests also passed after the bridge change. The C bridge passes `-Wall -Wextra -Werror`,
and the release desktop builds. The updated Xvfb/llvmpipe live capture drew 349 GUI frames and
rendered 279,552 audio frames; its recording contained 277,504 finite stereo frames at 48 kHz,
with channel peaks of 0.69902 and 0.70040. After unlocking GNOME, the older preview was closed
and replaced with this release build in the real Wayland session. Play/stop responded, and
`pw-dump` confirmed both stereo links active to Built-in Audio Analog Stereo.

On 2026-09-26, the MIDI-enabled desktop was also exercised through XWayland. Audio →
Built-in Audio Analog Stereo changed the checkmark from System Output to the explicit device;
`pw-link -l` confirmed both stereo links to that sink. System Output was then restored. The
clean release preview is left running through XWayland with playback stopped. Native Wayland
menu switching has a separate reproducible GTK/compositor limitation described below.
Logs: `~/driftbox-audio-private-tests.log`, `~/driftbox-audio-route-release.log`,
`~/driftbox-audio-route-capture.log`, `~/driftbox-audio-route-tests.log` and
`~/driftbox-audio-route-preview.log`.

These are ARM64 VM tests using virtual sinks. Physical USB/Bluetooth hotplug, hardware rate/profile
changes, suspend/resume and latency/glitch measurements remain release qualification work. Sink
names are read at discovery; a description changed in-place on an existing node may remain stale
until that node is announced again. The harness currently requires WirePlumber 0.4 configuration;
it deliberately refuses newer versions rather than enabling hardware monitors by mistake.

### Native MIDI

`ALSAMIDI` implements `MIDIInputPort` and `MIDIOutputPort` in `DriftboxHostLinux`. The desktop
passes the same backend to the shared session, so the existing MIDI input/clock settings and rack
listener use it without changing the shared protocols. The client publishes `Driftbox: Input`
and `Driftbox: Output`; `.virtual` sends from Output to its subscribers. It does not subscribe to
its own output. ALSA sequencer access (`/dev/snd/seq`) and `libasound` are required. Failure to
open MIDI is logged while the desktop continues with audio and editing available.

The worker discovers readable sources and writable destinations, subscribes to sources, and
reports source changes. Names combine the ALSA client and port names; numeric ALSA addresses
are used only for the current connection. Duplicate names receive a suffix in enumeration order,
so identical controllers are not yet reliably distinguishable across reordering. Per-source
ignore preferences filter delivery. Topology announcements trigger discovery, with a 250 ms
fallback scan. Port/client exit invalidates queued output and subscriptions before reconnection,
including when ALSA reuses an address.

Channel messages, MIDI clock, Start/Continue/Stop and song position use MIDI 1.0 short messages.
Program/channel-pressure callbacks are padded to the shared three-byte format. SysEx output is
rejected and incoming SysEx is skipped; MIDI 2.0/UMP is not implemented. Input stamps use
`HostTime` at receipt, not kernel capture timestamps. Output uses the shared `MIDIQueue`, with
`ppoll` and an eventfd waking the worker when an earlier message arrives. It sends only when the
monotonic timestamp is due. The queue is capped at 16,384 messages; invalid messages, missing
ports, shutdown and a full queue return false from `send`. This means accepted for scheduling,
not a guarantee of eventual hardware delivery. Runtime send errors are exposed by `error`.
Flush is serialized with delivery and affects only that destination. Shutdown sends messages
already due (including the session's final Stop), drops future messages, closes the sequencer and
joins the worker; shutdown from a callback safely avoids joining itself.

```sh
# Opt-in: publishes temporary named software ports; no physical MIDI device is needed.
DRIFTBOX_TEST_ALSA=1 scripts/linux-build.sh test --filter ALSAMIDI
# The message-validation test runs without a sequencer device as part of ordinary CI.
scripts/linux-build.sh test --filter ALSAMIDIMessageTests
```

Six tests passed on Ubuntu ARM64 with strict actor checks: short-message validation; callback,
clock and virtual-port delivery; future timestamps, ignore and selective flush; hotplug with stale
queued output discarded; bounded scheduling and final Stop delivery; a final Stop surviving
discovery after its source exits; and shutdown from a callback.
The C bridge passes `-Wall -Wextra -Werror`. The release desktop smoke test with PipeWire and
ALSA enabled passed under Xvfb/llvmpipe with 348 GUI frames and 278,528 audio frames. Logs are
`~/driftbox-midi-tests.log`, `~/driftbox-midi-release.log` and `~/driftbox-midi-desktop.log`.

This is software-port qualification. USB/Bluetooth MIDI, physical clock drift/jitter under load,
suspend/resume, sustained input overruns and reconnect after loss of the sequencer itself remain
unverified. Fatal sequencer failure currently stops MIDI until the app is reopened; runtime MIDI
errors also need presentation in the UI. On 2026-09-26, interactive XWayland checks confirmed
MIDI → Inputs lists `Midi Through: Midi Through Port-0`, with its checkmark removed when disabled
and restored when re-enabled. `aconnect -l` confirmed the desktop's Input/Output ports and its
subscription to Midi Through. The clean release preview now includes this MIDI backend.
An end-to-end physical controller/rack check remains pending.

### Native Wayland menu qualification

On this Ubuntu 24.04 VM (GTK 4.14.5 / GNOME Wayland), F10 opens File, but Left/Right to another
menu can dismiss its popup and leave the menu label focused. The same sequence succeeds under
XWayland. Temporary event/focus tracing confirmed the key arrives and the canvas does not
intercept it; the menu model is not rebuilt during the transition. A `WAYLAND_DEBUG=1` trace
shows the old popup destroyed, the replacement requesting a grab, and the compositor replying
`popup_done`. GTK then retries, but the popup remains unusable. `GSK_RENDERER=gl` also reproduces.

`scripts/linux-menu-probe.c` reproduces the visible failure using only GTK, a native text entry
and three static menus: no Driftbox, Swift, GLArea, PipeWire or ALSA code. This narrows the problem
to the environment/toolkit/compositor path; it does not yet identify an upstream defect or rule
out the VM input delivery mechanism. Run from a terminal in the signed-in guest:

```sh
cc -Wall -Wextra -Werror scripts/linux-menu-probe.c -o /tmp/driftbox-menu-probe \
  $(pkg-config --cflags --libs gtk4)
GDK_BACKEND=wayland /tmp/driftbox-menu-probe
# Press F10, then Left: the MIDI popup should remain visible and accept Down/Return.
GDK_BACKEND=x11 /tmp/driftbox-menu-probe
```

Use `GDK_BACKEND=x11 EGL_PLATFORM=x11 scripts/linux-build.sh desktop` for interactive work in
this VM. This is a native GTK application using XWayland within the existing GNOME session;
it does not change the desktop session or system settings. Before claiming native Wayland
support, repeat with physical keyboard/mouse input and a newer GTK/compositor, then retest all
menu/submenu transitions. Preserve normal GTK focus handling until that comparison establishes
which component needs a fix. Diagnostic logs from this run are
`~/driftbox-menu-wayland-protocol.log`, `~/driftbox-menu-wayland-gl.log` and
`~/driftbox-menu-x11.log`; the clean release log is `~/driftbox-midi-x11-preview.log`.

### Desktop validation

```sh
xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
  SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6 \
  scripts/linux-build.sh desktop --silent --smoke-test
# Live PipeWire capture, restricted to this test's child app output ports:
xvfb-run -a env EGL_PLATFORM=x11 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
  SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=swift6 \
  python3 scripts/test-linux-play.py --desktop .build-linux/release/driftbox-linux
```

The smoke run loads a song, starts and stops its transport, switches to the rack, requires rendered
rack frames and closes normally. With audio enabled it also requires at least one second of output
frames and no route error. The final live capture verified 297,984 stereo frames at 48 kHz, finite samples
and peaks of 0.67445 on both channels; the desktop drew 357 frames and the audio stream rendered
296,960 frames. This verifies the shared app and audio path on Xvfb/llvmpipe in the ARM64 VM.
Physical speaker output and sustained latency/glitch behavior are not established.

The shared desktop builds on macOS. All 20 desktop tests, including synchronous behavior and deferred-dialog regressions, pass on Linux.
The silent smoke drew 357 frames; an unavailable PipeWire server still allowed 358 GUI frames and
then returned the expected smoke-test failure with an audio diagnostic. The C desktop bridge passes `-Wall -Wextra -Werror`. CI now includes the
silent desktop smoke run; remote CI and Windows builds have not run for this change.

The first full-desktop Wayland smoke attempt happened while GNOME's display was idle/locked: audio
advanced but only one GUI frame was delivered, so the frame assertion correctly failed. After
unlocking, the full app passed the same test: 1,088 GUI frames and 280,576 audio frames through
virgl/ANGLE (Apple M4 Max), GLES 3.0. Log: `~/driftbox-desktop-wayland-unlocked.log`.

Visual inspection confirmed the groovebox and Pocket Sequence rack. Keyboard-driven checks
confirmed Space play/stop, Ctrl+R rack switching, Ctrl+O Open and Escape cancellation, and
Ctrl+Shift+S Save As. The native save wrote a new `~/driftbox-native/Acieed.driftbox` test document
with a valid versioned song payload. A subsequent check saved a new `b.driftbox` copy, confirmed
Open returned to the saved folder, selected `Acieed.driftbox` and reopened it successfully: the
song title changed back and its transport advanced. Playback was then stopped. Dirty-document
confirmation, pointer editing and WAV import still need interactive qualification. UTM computer
control did not reliably forward pointer movement and dropped characters during long text entry,
including inside GTK's own chooser; do not treat these automation failures as established app bugs.

At the user's request, GNOME's idle delay on this development VM is now 1,800 seconds (30 minutes),
up from 300 seconds. Automatic locking remains enabled, with its existing zero delay after idle.
This is local development-machine state, not a setting applied by the bootstrap script.

After adding file drops and remembered folders, the release build, C bridge warning checks,
20 desktop tests and two file URI tests passed. The URI tests cover spaces, embedded newlines,
Unicode names, ordering and rejection of remote/relative locations. The updated silent desktop
smoke passed with 353 GUI frames and normal shutdown. These checks do not replace a file-manager
drag/drop check.

Guest logs: `~/driftbox-desktop-{release,final-tests,capture,silent}.log`,
`~/driftbox-gtk-files-tests.log` and `~/driftbox-desktop-files-{tests,build,smoke,preview}.log`.

### Document and sample qualification

`scripts/test-linux-dialogs.sh` compiles the actual C shell implementation with warnings as errors
and runs seven GTK bridge checks on a private Xvfb display. It uses a temporary home and in-memory
settings, leaving the live desktop's file-chooser preferences alone. Coverage includes Save,
Discard, Cancel and window-manager dismissal; concurrent request rejection; Save followed by its
chooser; single/multiple Open cancellation and retry; menu action dispatch; teardown cancellation;
and accepted Open/Save paths with remembered folders. A filename containing spaces, Unicode and
an embedded newline must survive the URI boundary intact. Selecting a save location does not write
or overwrite a document; the shared document layer owns that operation.

These checks pass on the Ubuntu ARM64 VM and are wired into CI. The C fixture omits the renderer
and Swift dispatch integration, and drives GTK response callbacks directly; it does not establish
that compositor focus, keyboard navigation or a desktop portal works. The executable's existing
`--smoke-test` additionally checks all four completion-based requests through `any ShellWindow`:
each must remain pending until GTK responds, cancel exactly once on disposal, and tolerate repeated
disposal. The release smoke passed all four requests, then rendered 246 GUI frames and closed
normally on Xvfb/llvmpipe with audio disabled. This belongs in the executable because Swift Testing
already owns the dispatch main loop, leaving no main-queue eventfd for the GTK shell to borrow.

The targeted Ubuntu test run passed all 20 shared desktop tests and all 11 WAV decoder/sample
session tests under strict actor checks. The latter cover WAV encodings, malformed files,
resampling and pitch/duration, sampler playback and graph rebuilds, multisampler note mapping,
and stereo audio-track playback. They render and inspect samples without a physical audio device.
Together with the previously verified native save/reopen, these establish the underlying document
and sample paths. Interactive qualification follows below; WAV drop remains open.

In the installed XWayland preview, clearing Hothouse's automation marked the document edited and
Undo restored both its automation and clean title. Playback was left stopped, and no song file was
overwritten. The first attempts to invoke New were inconclusive through UTM input; the later
keyboard-driven check below successfully exercised the prompt and save continuation.

Guest logs: `~/driftbox-document-sample-tests.log`, `~/driftbox-gtk-dialog-tests.log`,
`~/driftbox-dialog-build.log` and `~/driftbox-dialog-smoke.log`. Remote CI has not run.

### Relocatable preview package

Build and package inside the Linux VM (Python 3.11 or later for packaging):

```sh
PATH="$HOME/.local/share/driftbox-toolchains/swift-6.4.0-RELEASE/usr/bin:$PATH" \
  swift build --scratch-path .build-linux -c release -j 4 --product driftbox-linux
python3 scripts/linux-package.py
python3 scripts/test-linux-package.py
```

The packager writes an extracted folder and `.tar.gz` under `dist/linux`, named by version,
architecture and executable hash. It refuses to overwrite an existing output. `--build-dir`,
`--toolchain` and `--output` allow alternate locations. It inspects a trusted local executable with
`ldd`; do not use it on an untrusted download. It copies the transitive Swift runtime dependency
closure, the two SwiftPM `.bundle` directories, the existing Driftbox icon and runtime notices.
A manifest records file hashes, architecture, Swift/build OS versions and bundled/system libraries.
GTK, Pango, graphics drivers, PipeWire, ALSA and other distribution libraries stay system dependencies.
Runtime notices are pinned to Swift 6.4.0; changing toolchains requires requalification.

The `Driftbox` launcher finds libraries beside itself, preserves file arguments and working
directory, and enables strict Swift actor checks. `--x11` selects the tested VM workaround.
`python3 install.py --x11` registers the extracted folder in place in the user's app menu and adds
`.driftbox` MIME recognition with an Open With handler. It does not select a default handler or
claim generic JSON files. Registration needs `desktop-file-utils` and `shared-mime-info` and runs
without sudo. `--uninstall` removes only owned registration entries, preserving the bundle,
documents and Foundation preferences. See [the bundled guide](../linux/README.md).

Nine Python checks pass on Ubuntu, including real GIO desktop-entry launch with spaces, quotes,
dollar signs, backticks and backslashes in the executable path; file argument forwarding; launcher
environment/cwd; upgrade ownership; foreign/modified entry protection; symlink rejection; and
incomplete bundles. CI runs these checks with desktop-file-utils and Python GObject bindings.

The 2026-09-26 ARM64 archive is 29.3 MiB compressed, with 15 runtime libraries. Its archive was
extracted separately and tested inside a temporary Bubblewrap mount namespace with all of `/home`
hidden (including both the source checkout and Swift toolchain), a fresh HOME, and the bundle mounted
at a path with spaces. `ldd` resolved the runtime from the bundle without missing libraries. The
silent Xvfb/llvmpipe test loads the song, requires a populated rack and module picker, draws the rack
and closes normally (256 GUI frames). The namespace changes only the test process's filesystem view;
it does not rename, delete or alter the actual development home. This proves relocation and resource/runtime
independence on the existing Ubuntu installation, not fresh-machine or cross-distribution support.

The first qualified package `Driftbox-0.1.0-preview-arm64-1ce5b839fb3d` was installed under the guest's
`~/Applications` and registered as **Driftbox Linux Preview** with `--x11`. All 67 manifest file
hashes match. Live PipeWire capture from that installed bundle verified 280,576 stereo frames at
48 kHz, finite samples and peaks of 0.67445; the app rendered 282,624 audio frames and 242 GUI frames.
Ubuntu's app search displays the Driftbox icon and launches the installed app successfully, restoring
Acieed with playback stopped. Process mappings confirm Swift and ICU are loaded from the installed
bundle. That build used GTK's generic running-window dock icon; the follow-up below resolves it. Logs: `~/driftbox-package-final-isolated.log`,
`~/driftbox-package-audio-capture.log`, and `~/driftbox-package-build.log`. Remote CI has not run.

### Desktop identity and native Wayland follow-up

The preview now sets `org.driftbox.linux.preview` before GTK opens its display, matching its
installed desktop-file basename; the desktop entry also declares `StartupWMClass`. GTK searches
beside the resolved executable for the bundled `Driftbox.png`, so icon lookup does not depend on
the working directory or a global icon-theme installation. This follows GTK's
[desktop identity guidance](https://gnome.pages.gitlab.gnome.org/gtk/gtk4/migrating-3to4.html).
The ARM64 bundle `Driftbox-0.1.0-preview-arm64-fc587bb5b454` is installed under the guest's
`~/Applications`, registered with `--x11`, with all 67 manifest hashes verified. Packaging checks
(nine), GTK bridge checks (seven), and the packaged Xvfb smoke (304 GUI frames) pass.

Interactive Ubuntu Files qualification also passes: **Open With Driftbox Linux Preview** launches
`~/Documents/Driftbox QA/Launch with spaces.driftbox`, a copy of Acieed. Both the window title and
song header show **Launch with spaces**, the rack/sequence renders and playback advances. The
running dock now displays the Driftbox icon. Process arguments confirm the installed bundle receives
the complete path as one argument. Playback was stopped through the Transport menu; the song remains
unmodified. No default file association was explicitly changed.

UTM input automation can drop long text and modifier-key releases in Ubuntu Files as well as Driftbox.
For this check, entering paths in short text chunks with a UI observation between chunks worked;
keyboard menu navigation worked with an observation between actions. Treat dropped VM input separately
from application failures when qualifying interactive workflows.

Wayland protocol logging confirms `xdg_toplevel.set_app_id("org.driftbox.linux.preview")`.
However, rapid native chooser creation/destruction in the dialog smoke revealed an additional
GTK 4.14.5 Wayland failure: SIGSEGV in `gtk_widget_get_display`, reached from GTK's Wayland event
handling after a text-input enter event. A GTK-only program reproduces the same backtrace without
Swift, Driftbox callbacks, audio or GLES. It completes on X11. One full Wayland smoke without
protocol tracing passed (431 GUI frames), so timing matters; do not interpret that pass as resolution.

The standalone reproduction is `scripts/linux-dialog-probe.c`. From the unlocked guest desktop:

```sh
cc -Wall -Wextra -Werror scripts/linux-dialog-probe.c -o /tmp/driftbox-dialog-probe \
  $(pkg-config --cflags --libs gtk4)
GDK_BACKEND=wayland WAYLAND_DEBUG=client GSETTINGS_BACKEND=memory \
  /tmp/driftbox-dialog-probe
```

This deliberately opens and immediately destroys native choosers before processing pending events.
It can crash on the affected stack; it is a diagnostic, not a passing CI check. Retest with newer
GTK and physical Linux hardware, and qualify normal dialog cancellation/close and input methods
before enabling native Wayland for release. The installed preview continues to use XWayland.
Logs: `~/driftbox-identity-{x11,wayland,gdb,gdb-trace}.log` and
`~/driftbox-gtk-only-dialog-{crash,x11}.log`.

### Interactive documents and rack audio import

The 2026-09-26 follow-up qualified the edited-document flow in the installed XWayland preview.
After clearing Hothouse's automation, **File → New** showed the native save question. Cancel kept
Hothouse edited. Choosing Save, then cancelling Save As, also preserved the edit and allowed a
second New request. Retrying Save wrote `~/qa-saved.driftbox` (10,839 bytes), then continued to a
blank, stopped Untitled song. Ubuntu Files reopened that copy with its name, sequence and cleared
automation intact. The built-in song was not overwritten. Interactive Discard remains to check.

**Rack → Load Audio Into** now lists the current patch's samplers, audio tracks and multisample
instruments, numbered within each type. It shares the module-face chooser and asynchronous loading
path, allows several WAVs for multisample instruments, and disables missing/busy targets and
commands while a dialog is pending. This supplies a keyboard route to import without requiring
canvas pointer interaction; it is not a complete canvas accessibility implementation.

In Cut Up, **Load Audio Into → Sampler 1** opened the native WAV chooser. Accepting
`~/Documents/Driftbox QA/QA tone.wav`, a two-second 44.1 kHz 16-bit stereo fixture, returned to the
rack and started playback at 240 BPM (the existing loader's two-bar fit). Transport stopped it
successfully. The sampler face was below the viewport; UTM scroll input did not move the canvas,
so waveform/name display and pointer/drop interaction are still unqualified. Physical listening
was not assessed in this check.

The installed bundle is `Driftbox-0.1.0-preview-arm64-ce5e48b22bcd`, registered with `--x11`.
All 67 manifest hashes verify. The release build, 21 desktop tests with strict Swift actor checks,
and packaged silent Xvfb smoke pass (354 GUI frames, all four deferred dialogs cancelled exactly
once). The new regression covers single versus multiple selection, cancellation without patch
mutation, pending-dialog command gating and targets following patch changes. Existing GTK
`thaw_updates`/transient-parent diagnostics still appear during the rapid dialog smoke; they are
not resolved by this change. Remote CI and Windows/macOS builds of this follow-up have not run.
Guest logs: `~/driftbox-audio-menu-{tests,build,package,smoke}.log`.

### Keeping the Linux branch current

The 2026-09-26 integration merges `origin/main` at `ea78956` (69 upstream commits since the
previous common base). Preserve the shared desktop's accessibility actions and focus, exports,
recent files, plug-in faces and visuals-window lifecycle alongside Linux's deferred dialogs.
The EGL chooser now uses main's window-plus-pbuffer selection with a pbuffer-only fallback;
the GTK borrowed-context path remains intact.

New mix, stem and movie export requests use completion-based choosers, with a native GTK folder
chooser for stems. Recent-file opening waits for the unsaved-document question, and Linux keeps
case-distinct paths separate. The Linux launcher supplies the desktop's persistent file memory.
Movie export and performance recording are disabled on Linux until a movie writer is implemented.
Shared accessibility semantics still need a GTK assistive-technology adapter; separate visuals
windows still need a GTK window/surface implementation. Neither is claimed as completed by the merge.

Validation: the default Linux shared suite succeeds (583 reported tests, with generated-reference
fixtures and opt-in live audio/MIDI checks skipped). All 36 desktop tests pass after adding the
deferred export, unsaved-recent and case-sensitive-path regressions. All eight GTK bridge checks,
nine Linux packaging checks and strict project-wide Swift formatting pass. On the Mac host,
`scripts/check-constrained.sh` passes both Embedded Swift compilation and the release build's
allocation checks; the release-script checks pass (11 desktop, seven Android). Windows builds
and remote CI have not run for this merge.

The final Linux release package is `dist/linux-main-sync/Driftbox-0.1.0-preview-arm64-cd0c0d896c8d`
in the guest checkout, with 15 runtime libraries, 67 verified manifest hashes and a 29.7 MiB archive.
Its Xvfb smoke passes: 286 GUI frames and all five deferred dialog types cancelled exactly once.
This is a silent graphics/lifecycle check, not physical audio qualification. The existing desktop
installation remains the previously qualified bundle; this package has not been registered over it.

Adding the folder chooser to the immediate show/destroy stress case exposed a GTK 4.14.5 crash
on X11 too: an asynchronous file-model callback faults inside GTK/GIO after the chooser is gone.
The extended `scripts/linux-dialog-probe.c` reproduces it without Swift, Driftbox or GLES. The app
smoke now runs GTK's main loop for 250 ms per chooser before closing its parent and testing disposal;
normal presentation/disposal passes, but this does not fix or qualify the immediate teardown race.
Retain the standalone stress probe and retest with a newer GTK before release. Logs in the guest:
`~/driftbox-main-sync-{tests,desktop,build,dialogs,package,smoke,smoke-gdb,gtk-only}.log`.

Before each Linux implementation milestone, fetch `origin/main`, inspect the divergence, and merge
new shared changes into `codex/linux-port`. Check new shell requests for synchronous assumptions,
platform-only capabilities and resource ownership, then run the affected tests in Ubuntu. Keep
integration commits explicit so Linux adaptation work can be reviewed separately from upstream.

### Local access

The VM uses UTM Shared Network. Its first assigned address is `192.168.64.2`; discover the current
one with `utmctl ip-address "Driftbox Linux"`. The dedicated SSH configuration is outside the repo:

```sh
ssh -F '/Volumes/StudioData/Virtual Machines/Driftbox Access/ssh_config' driftbox-linux
```

The account is `driftbox`, authenticated by its VM-only SSH key. Console password login is locked
in the initial cloud image. To choose a desktop password, run this interactively in a Mac terminal,
then sign in as `driftbox` in UTM (SSH remains key-only):

```sh
ssh -t -F '/Volumes/StudioData/Virtual Machines/Driftbox Access/ssh_config' driftbox-linux sudo passwd driftbox
```

The guest account has passwordless sudo for development. Automatic desktop login is not enabled.
There is no shared host directory. The guest sees its own disk, setup image and virtual devices.

When transferring source with macOS tar, use `--no-xattrs --no-mac-metadata` to avoid carrying host
extended attributes into the Linux checkout. Keep the guest build products on the guest disk.
