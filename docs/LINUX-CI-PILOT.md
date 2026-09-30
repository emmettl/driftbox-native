# Linux CI pilot on the Mac mini

30 September 2026. An on-demand Linux ARM64 worker is installed on the existing
24 GB CI Mac mini at `~/ci/linux-vm`. It uses direct QEMU/HVF hardware
virtualization: UTM's controller could not be operated through SSH because of
macOS automation permissions.

## Configuration and operation

- Ubuntu 24.04 ARM64; four virtual CPUs; **4 GiB guest RAM**.
- A 100 GiB growable disk on the mini's internal SSD; about 11 GiB occupied after
  provisioning and the first test build.
- Swift 6.4.0, Node 24.21.0 and Playwright 1.63.0 / Chromium 153.
- Two concurrent jobs for the main test build and cold-build benchmark; serial
  Swift test execution. The existing constrained-audio script also performs its
  own release build using SwiftPM's default concurrency.
- Guest SSH is forwarded only to `127.0.0.1:2224` on the mini, with a dedicated
  key. There are no host-directory shares or GitHub credentials in the guest.
- No automatic startup, recurring schedule or GitHub runner registration.

Run from the development Mac:

```sh
ssh scrimply-ci-tb '/usr/bin/python3 -u ~/ci/linux-vm/run-pilot.py'
```

The command starts the guest, runs the pinned Driftbox checks, saves logs and a
guest-results archive under `~/ci/linux-vm/results/<timestamp>`, then shuts the
guest down. It preserves a failing exit status if any check fails. The
[versioned harness instructions](../scripts/ci-linux/README.md) cover deployment,
guest prerequisites and manual operation. The mini's `pilot.json` records
installed source and image provenance.

## Resource admission

The launcher reserves both existing Scrimply `ci` slots while the guest runs.
Before starting it waits up to ten minutes for host work or occupied CI slots.
Other native builds and recorder processing cause the guest CPUs to pause, then
resume when that work finishes. Collection remains running.

This is cooperative admission with five-second polling, not atomic exclusion
for workloads outside Scrimply's semaphore. Elevated host memory pressure, a
pause longer than five minutes, cancellation/orphaning or a two-hour lifetime
limit shuts the guest down. An unresponsive guest is terminated after the
graceful-shutdown timeout. Changing the number of host CI slots requires updating
the launcher.

## Pilot evidence

The initial **6 GiB** trial completed a cold compilation but subsequently hit
host memory-pressure level 2 while tests and recorder processing were active.
The guard shut the guest down, after which pressure returned to normal. Observed
swap usage did not increase. This is why the installed configuration uses 4 GiB.

The completed **4 GiB** Swift run recorded **645 passed, 1 failed and 12 skipped**
JUnit cases in **9 minutes 46.65 seconds**, including an incremental build.
Guest available memory never fell below approximately **2,990 MiB** in the
two-second samples. Host pressure remained normal and swap stayed at the
pre-existing **612.88 MiB**. Real recorder processing caused successful guest
pause/resume cycles.

The failure is
`DriftboxEngineTests.SendAudioTests.theReverbSoundsLikeTheReference`: the
"reverb large and damped" case measured **−90.6616 dB**, outside the existing
**≤ −95 dB** bound. No product code or tolerance was changed. This is evidence
from this Linux ARM64 / Chromium combination, not proof of its root cause.

Evidence on the mini:

- `results/20260930-145255/`: full Swift run, JUnit archive and timing.
- `logs/memory-20260930-145255.jsonl`: host-memory samples.
- `logs/bootstrap.log`: Swift bootstrap and signature output.

The Swift archive verified with a good cryptographic signature, but the official
key bundle marks the Swift 6.x signing key expired, matching the existing
development VM's documented observation.

Source revision: `e985faf9b850728532a5ce3aee0e3e016be8c157`.
Pinned browser reference: `872bcca1a90723ca15f3a3d2fed0ad244eb7aa96`.

Independent integration checks, isolated failure reproduction and a cold build
at 4 GiB are complete:

| Check | Result |
| --- | --- |
| Cold build of all test products | Passed; 64.40 seconds reported by Swift, 65.12 seconds wall time |
| Isolated reverb comparison | Same failure and same −90.6616 dB measurement |
| GLES diagnostics | Passed on Mesa llvmpipe / OpenGL ES 3.2 |
| GTK dialogs, window lifecycle and desktop startup | Passed |
| PipeWire route selection, fallback and server restart | Passed |
| Release, Android release, Linux package and Debian package script tests | Passed |
| Embedded Swift and allocation constraints | Passed, including the release build |
| Live guard pause/resume test | Passed |

The cold build retained at least approximately 2,743 MiB available inside the
guest in the two-second samples. **Guest RAM is not total host overhead:** the
QEMU process's sampled RSS peaked at about **5.82 GiB** during the integration
and cold-build session, compared with 3.33 GiB during the serial suite. Host
pressure remained normal and swap remained 612.88 MiB in both completed 4 GiB
sessions. These observations are specific to this workload and host load.

Final evidence is in `~/ci/linux-vm/results/20260930-final/` on the mini and in
the [local evidence summary](evidence/linux-ci-pilot-2026-09-30.json).
At completion of this run, the VM was powered off, both reserved CI slots were
released, and the recorder's five collectors remained running with no reported
storage error.

This pilot does not qualify physical
audio/MIDI/GPU hardware, x86-64, or the full Docker package/install matrix.
Existing GitHub-hosted checks remain the release evidence.
