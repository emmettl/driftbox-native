# Android

Driftbox on Android is `Session` and `RackSession` with the controls on a touch screen
(`DriftboxTouch`), AAudio and Android's native MIDI behind the ports, OpenGL ES 3.0 under the
scenes, and Android's own text stack for type. The app is built without Gradle, by the SDK's own
tools. How the parts fit together is in [architecture.md](architecture.md); releasing it is in
[RELEASING.md](RELEASING.md#android).

## Toolchain

A swift.org toolchain and swift.org's Swift SDK for Android of the same version, and the NDK that
SDK names: Swift 6.4.0 and NDK r30. It builds on Windows from Git Bash, on a Mac, or on Linux,
which CI builds it on. On a Mac the toolchain is swift.org's, in `~/Library/Developer/Toolchains`,
not Xcode's own Swift, which the SDK is not built for. `swift sdk install` puts the SDK where the
scripts look, and Android Studio the NDK. `scripts/android-env.sh` says where each is looked for
on each host, and how to point at another. The app also needs a JDK, and the Android SDK's
build-tools and platform beside the NDK.

It uses swift.org's SDK rather than the Android platform the Windows installer brings, whose
standard library has no SIMD types and whose arm64 runtime cannot link Foundation. The build sets
the SDK up the first time, as its own script would.

The NDK has to be the one the SDK names, not only a recent one. The Swift runtime is built against
that NDK's C++ library, and linked with an older one it links and is then refused by the phone for
want of a function (6.4.0's wants `std::__hash_memory`, which r30's libc++ has and r29's has not).
`android-app.sh` looks for every such function in the libc++ it packs, and stops if one is
missing.

## The player

```bash
scripts/android-play.sh                    # acid through the phone's speaker, for twenty seconds
scripts/android-play.sh song.json --seconds 60
scripts/android-bench.sh                   # --bench, once on each kind of core the phone has
```

Each builds `driftbox-play` for arm64 Android with `android-build.sh` and pushes it to
`/data/local/tmp`. There is no app and no install: Android runs a plain executable, linked
statically.

## The app

```bash
scripts/android-app.sh                  # build and install; it opens on Pulse, playing acid
scripts/android-app.sh build            # build only, with no phone
scripts/android-app.sh release          # build it as it is released, without the tests: what CI does
scripts/android-app.sh bundle           # and an App Bundle beside it, for Google Play
adb shell am start -n app.driftbox/.Main --es song smallhours --es scene hothouse
scripts/android-app.sh midi-loopback    # test the MIDI ports against the app's own loopback
scripts/android-app.sh gpu              # or the GPU contract on the phone's GPU
scripts/android-app.sh scenes           # or every scene drawn, checked and timed there
scripts/android-app.sh text             # or the typesetter, held to what every platform's is
scripts/android-app.sh rack             # or every patch of the rack's run, and recordings decoded
```

Opened, the app plays a song from the catalogue with the scene the song names drawn over the whole
screen, the controls over it, and the rest of the screen the performance filter's pad. Given a
test's name, the app runs that instead and says what happened. A release has no tests in it, nor
the MIDI loopback they test against, which every other app on the phone would list. Its icon is an
adaptive one, drawn as vectors, the Mac's and the web's picture placed as the web's maskable icon
places it: `scripts/android-icon.mjs` writes it.

An arm64 emulator runs the app's checks as a phone does, from a Mac with no phone to hand. Drawing
in software, the scenes want `DRIFTBOX_ANDROID_WAIT=300` rather than the thirty seconds a phone
takes.

### The touch interface

`DriftboxTouch`'s `Touchscreen` is `Desktop`'s counterpart for a screen with no window to ask
things of, and iOS can use it as it is. It draws the scene at no more than two pixels to a point,
lays the controls over it at every pixel, and decides what each finger is: the controls' if it
lands on them, the pad's if it is the first anywhere else, and a second finger tapped steps on to
the next scene. It lays the controls out for fingers: a phone's narrower than 600 points, kept
upright, and a tablet's or a roomier phone's wider, turned either way.

Everything but the audio is on Java's main thread, as a desktop's is on its window's: Java's
`Choreographer` asks for each frame and hands over each finger between them, and a window is let
go of before Java's `surfaceDestroyed` returns, as Android wants.

The rack is on the touch screen too, reached from the song's chip: its modules' faces, and on the
back their jacks, with cables dragged from either end and trims beside each input. The rack moves
about under a finger and zooms to fit a module or the whole of it. Edits have undo and redo, and a
MIDI keyboard plugged in plays the app as it does on a desktop.

Help is the same `HelpSheet` the Windows app draws, in Android's terms: what a finger does (taps,
holds, the step keyboard, pinching the rack) and nothing of keys. The song's chip offers the
Groovebox Guide and the rack's patch chip the Rack Guide. The rack's guided tours run on the drawn
rack as on Windows, their panel across the top of a phone, started from the patch chip's menu.

### Songs and what is remembered

Songs open and save as `.driftbox` through Android's own pickers, from the song's menu: its name,
at the head of the strip, tapped. Java reads and writes the document whole and hands Swift its
text and its URI (`FileLines` in `Sources/DriftboxAndroid` says what passes between them), and the
session keeps the URI as the song's id, so Save writes back to the document it came from. Android
asks before unsaved edits are lost.

What the app remembers between launches (the song open last, which it plays when started without
one, the click and the other settings, the output chosen, and the rack's patch and the controllers
learnt onto it) is in `settings.json` among its own files, written by `FileMemory`, since
`UserDefaults` is the old Foundation's there. The rack session keeps what it remembers in a
`RackMemory` in the same way.

### Without the old Foundation

The session finds its songs as files, where the app unpacks them from its package, rather than
through `Bundle`: on Android that, `String(format:)` and `UserDefaults` are the old Foundation, and
it brings 48MB of internationalisation with it. The build tells the compiler not to link the old
Foundation at all, and fails a library that still asks for any of it, which the phone would
otherwise refuse only as it loaded. The package is 17MB.

The rack session does the same: it finds its patches beside the songs, reads its learnt
controllers with `JSONDecoder` rather than `JSONSerialization`, sample names with the standard
library's `Regex`, and writes numbers without `%f`; and on Android it has its own `CGPoint` and
`CGRect`, which the old Foundation gives Windows. `scripts/android-app.sh rack` opens every patch
in the catalogue on the phone and runs it until it sounds. All eleven do, each in its first second
but Pressure System, a song that comes in in its seventh, as it does on Windows; a second of any
costs the phone 9 to 127ms.

## Audio

AAudio: low-latency mode, exclusive if the device will give it, float stereo at 48 kHz. AAudio
makes the render thread; Driftbox keeps it to the big cores, since left to the scheduler it
underran a hundred times a second, and reports each callback's work to a performance hint session.

**The buffer** starts at two bursts, 4ms, and grows a burst at a time if the stream underruns. One
burst, the least a stream can have, crackled once the app drew its controls, though AAudio counted
no underruns: its slowest callbacks took up to 3.6ms of a 2ms burst, and with two bursts, 4.1ms of
4. Timing every callback showed why: one in eleven, every 1,024 frames, took twice the
rest, because the reverb's tail did a whole block's work in the callback its block ended in. The
reverb spreads that work over the next block (`SpreadConvolver`), and the slowest callback of a
second is 2.1 to 2.6ms, with the heaviest scene drawn, on any of five songs: room in two bursts, where it had taken three, 6ms, to hide the spikes.

**Devices.** A stream whose device goes away ends and asks to be replaced, as on Windows. AAudio
plays through a device by number but cannot list them, so the app's Java lists them from
`AudioManager` as they come and go, each with an ID that stays the same when it is plugged in
again. The song's menu offers them under Output, beside Automatic, which is wherever Android sends
the sound. A device chosen and unplugged is kept, and Automatic played through until it is back.

**Out of view**, or with the screen off, the song plays on and nothing is drawn. A media playback
service, with a notification to stop it from, keeps the process on the big cores, which Android
otherwise takes away from an app out of view. There the render thread costs half as much again as
in view, with no drawing to keep the cores awake, so the stream's buffer goes to sixteen bursts at
once, 32ms, and back in view. On a Fairphone 6, twenty seconds with the screen off underran once,
as it went off. A call, or another app's playing, pauses it, as media does.

## MIDI

Android's native MIDI, which needs Android 10, so Driftbox builds for API 29. It can play through
a device but not find or open one: that is Java's `MidiManager`. So the app opens every device and
hands each to `AMidiDevices`, and `AMidiInput` and `AMidiOutput` open their ports from there.

- **Input** is read by a thread that asks every port in turn, since there is no callback, and a
  `MIDIByteStream` per port makes Android's packets back into messages: running status, clock in
  the middle of a note, system exclusive skipped.
- **Output** is stamped, and what a stamp means is the device's business: Android's USB driver
  holds a message until then, by its source, but a device that is another app is handed it at
  once. So for every device but USB, `AMidiOutput` holds each message in a scheduler of its own
  until it is due, and sends it stamped, as WinMM's scheduler does on Windows. The two share
  `MIDIQueue` in `DriftboxHost`, and each waits in its own way.

Driftbox Loopback is a MIDI device the app publishes that sends back what it is sent, so the ports
are tested with nothing plugged in, as on Windows. Notes and clock come back whole and in order,
stamps exact. A clock sent ahead goes out when it is due: a beat of it, tick by tick, 0.1 to 2ms
after each tick was due, and a flush drops what has not gone. Without the scheduler it came back a
tenth of a second early, the moment it was sent, and a flush dropped nothing.

## Drawing

A scene is drawn at no more than two pixels to a point, a Mac's Retina display's, and scaled up to
the screen. On a Fairphone 6, which has three, every scene but Frost then keeps the display's 120
frames a second, and Frost 98. Graphic Lab, which sets its type with Android's own text stack,
takes 5.6ms a frame, and more over its first frames at a size, while the glyphs it sets go into its
atlas. The GPU backend and the typesetter are described in [gpu.md](gpu.md).

What the render costs on a phone is in [performance.md](performance.md).
