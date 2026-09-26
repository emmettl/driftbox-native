# Linux port

Linux has two independent tracks: a development machine and a native application. A VM that
builds the shared code is useful progress, but does not establish that the desktop port works.

## Scope of the first release

A standalone ARM64 and x86-64 desktop application using the existing `Desktop`, `Session`,
`RackSession`, instrument engines, document codecs and canvas interface. It should play and edit
songs, run the built-in rack, save/reopen documents, import WAV samples, export audio, and exchange
MIDI notes and clock. Linux plug-in hosting and publishing Driftbox as a plug-in are later work.

Target Ubuntu 24.04 LTS first. Test both Wayland and X11 before claiming support for either.
PipeWire now powers the command-line audio output; ALSA sequencer is the proposed MIDI backend, GTK 4/Pango the
proposed shell/text stack, and GLES the existing renderer. The GTK decision remains provisional
until the context and event-loop experiments below pass. Do not introduce a second UI or engine.

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

`Desktop.run()` delegates the loop to `ShellWindow.run(frame:)`. `GPUSurface.present()` currently
promises to wait for the display and pace that loop. GTK instead schedules render callbacks.
Test a callback-driven shell before changing these contracts. Separate frame scheduling from
presentation if necessary; avoid a permanent busy loop, including when hidden or minimized.

The loop must also run Swift `MainActor` tasks: sample-loading completions, delayed saves and
plug-in operations. `post` alone does not prove that arbitrary Swift tasks resume. Windows uses
explicit libdispatch integration; do not assume that GTK callbacks automatically supply this.
A small experiment must prove actor isolation and background-to-main completion before shipping.

### Allow toolkit-owned graphics contexts

`GLESDevice` creates an EGL display/context and offscreen pbuffer. Linux requests only pbuffer
support so Mesa's surfaceless configurations work; Android also requests window support. `GLESSurface` is
Android-only and assumes framebuffer zero for the window. GTK's GLArea supplies its own current
context and framebuffer. Add an explicit context/surface ownership boundary if GTK is retained;
keep the existing headless EGL path for tests. Verify orientation, alpha, resize, context loss,
resource lifetime, frame pacing and fractional display scale. No new shader language is needed.

### Make document interactions asynchronous

The shell currently returns files, save decisions and context-menu commands synchronously.
GTK's current file dialogs are asynchronous. Prefer asynchronous completion through the shared
open/save/close flows over nested event loops. Test cancellation, save failure, a close request
while a dialog is open and repeated commands; no loss of unsaved work. Evolve Windows alongside
any shared protocol change. Use desktop file portals where appropriate for distribution.

### Complete input semantics

`KeyEvent` currently serves both shortcuts/instrument keys and text. Add committed text and
composition where editing needs them, and focus-loss handling that releases held notes and
pointer gestures. Retain point-based input and explicit pixel scale. Accessibility for the
canvas controls needs its own semantic adapter; a GTK window alone does not make those controls
accessible. Identify the intended first-release accessibility scope explicitly.

### Keep audio and MIDI adaptation local

Implement `DriftboxHostLinux` behind the existing ports. The audio callback must use preallocated
buffers and C-compatible render callbacks, without allocation, locks or actor work. Honour
`Mixer.rendering`/`buffers` and the guarantee that detach returns only after use of the source ends.
Handle variable buffer sizes, rate conversion, server/device loss and reconnect. Expose failures
instead of presenting a working route when the stream is not running. Stable device identifiers
must survive reconnects; PipeWire's transient numeric object IDs are not persistent preferences.

ALSA MIDI needs source changes, virtual ports, scheduled output and explicit conversion between
queue time and `HostTime`. Validate clock drift and jitter against physical equipment later.

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

Run `scripts/linux-build.sh doctor`, `build`, `gpu`, `test`, `play`, `bench`, or `render` **inside Linux**.
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
desktop shell is still to come.

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
The GUI, MIDI, sample import and packaging milestones remain unchanged.

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
real-device hotplug recovery. The next application milestone is the shell/context/concurrency
experiment, while audio device management can build on this stream implementation.

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
