# Playing, listening, and what it costs

`driftbox-play` plays a song through the speakers on every platform, and measures what the
render costs; `driftbox-render` writes one to a file. The numbers below were measured with them.

## Playing

```bash
swift run -c release driftbox-play conformance/fixtures/documents/acid.song.json --start-bar 8
swift run -c release driftbox-play song.json --seconds 30
swift run -c release driftbox-play song.json --bench
swift run -c release driftbox-play song.json --window    # its scene too: see visuals.md
```

It prints what reaches the output once a second. On the Mac the engine is an Audio Unit in an
`AVAudioEngine`; on Windows it plays through WASAPI, on Android through AAudio (see
[android.md](android.md) for the scripts that push it to a phone), and on Linux through PipeWire.

`--bench` runs the same engine with no device, as fast as it goes, and then runs the same calls
paced as a device paces them, one every 10.7ms with a sleep between.

## What the render costs

### The Mac

Unpaced, `--bench` runs at **3.3% of real time** on an Apple silicon Mac, of which the reverb is
about a third. Live, the render callback reports a fifth of the audio's time on its own clock, and
the difference is the platform, not the code: paced as a device paces them, the same calls cost
**16%**, five times the loop, because a core woken every ten milliseconds does its first
millisecond of work cold and slow. That is the number to budget for, and it is fine.

### Windows

The same command plays through WASAPI, and says which device and how far behind the speakers are:
10ms on a laptop's own. The render call costs **8 to 13%** of the audio's time there, its longest
2.8ms of a 10ms period. That is measured by wall time on the performance counter, since Windows
keeps a thread's own time only to its 15.6ms scheduler tick.

### Android

On a Fairphone 6, with a Snapdragon 7s Gen 3, `--bench` costs **13 to 16%** of real time on a big
core across the catalogue: four and a half times the Mac. On a little core it costs **69%**, so a
render thread must never land on one.

Paced, the big core costs **67%**, its longest call 9.7ms of a 10.7ms period. That number is the
phone, not the code: with the rest of the cluster kept busy, the same paced run costs **17.7%** and
its longest call 2.5ms.

- **It is not the clock**, though that was the first guess. Played through AAudio, in 2ms bursts,
  the render costs about **60%** of each burst whether a performance hint holds the cluster at
  2.2 GHz or lets it fall to 0.6; with the other big cores kept busy it costs **15 to 18%**.
- **Nor is it the waking.** Asked for callbacks four bursts long, a quarter as many, it costs the
  same **53 to 57%**, each call four times as long.

A call runs slowly the whole way through while the rest of its cluster idles, not only as its
core wakes. It is still in time: the heaviest song played for thirty seconds without an underrun,
its longest call 3.4ms, the speaker 4.8ms behind the render. How the app sizes its buffer and keeps
to the big cores is in [android.md](android.md#audio).

## Listening

```bash
swift run -c release driftbox-render conformance/fixtures/documents/smallhours.song.json smallhours.wav
swift run -c release driftbox-render song.json out.wav --start 15.2 --duration 8 --rate 48000
```

A song document in, a 32-bit float WAV out, at about thirty times real time. This is the native
render as the engine means it, without the browser's faults that the conformance tests switch on
(see [conformance.md](conformance.md)).
