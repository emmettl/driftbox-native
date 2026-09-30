# Mac mini Linux CI pilot

These scripts operate the on-demand Ubuntu ARM64 pilot on the 24 GB M4 Pro CI
Mac mini. The [pilot report](../../docs/LINUX-CI-PILOT.md) records its measurements
and outstanding reverb comparison failure. This manually operated pilot is not
registered as a GitHub Actions runner.

## Install or update

Scripts locate runtime files relative to themselves. Copy them into the existing
`~/ci/linux-vm` directory **on the mini**, with the guest stopped. From the
repository root on the development Mac:

```sh
rsync -av scripts/ci-linux/run-vm.py scripts/ci-linux/run-pilot.py \
  scripts/ci-linux/guest-ssh scripts/ci-linux/pilot-checks.sh \
  scripts/ci-linux/cold-build.sh scripts/ci-linux/provision-extra.sh \
  scripts/ci-linux/test-guard.py scripts/ci-linux/README.md \
  scrimply-ci-tb:ci/linux-vm/
```

This updates the harness; it does not import a new source revision or recreate
the VM. `scrimply-ci-tb` is the development Mac's SSH alias for the mini. The
launcher expects Homebrew QEMU under `/opt/homebrew`, macOS HVF, four vCPUs,
4 GiB RAM, and these existing runtime files:

| Path under `~/ci/linux-vm` | Purpose |
| --- | --- |
| `images/linux-ci.qcow2` | Provisioned Ubuntu 24.04 ARM64 disk, 100 GiB virtual size |
| `images/efi-vars.fd` | Writable EFI variable store |
| `images/seed.iso` | Cloud-init seed for the `ci` account and dedicated SSH public key |
| `keys/id_ed25519` | Dedicated private SSH key, readable only by the host account |
| `keys/known_hosts` | Guest host-key record, populated on first connection |
| `pilot.json` | Installed source and image provenance |

Disk images, seed material, credentials, source bundles, caches and raw results
remain outside Git. The adjacent `.gitignore` also excludes runtime artifacts
if a harness is accidentally run from this checkout.

## Guest prerequisites and source revisions

The installed guest has detached Git checkouts at `/home/ci/driftbox-native` and
its `driftbox` submodule, imported from trusted source bundles. Preserve Git
metadata: fixture generation needs it. Import a new native revision together
with its pinned reference and update the runtime `pilot.json` provenance.
The harness records both revisions and checks the submodule pin before testing;
it does not fetch or reset source code. The September pilot revisions are in
the report; its measurements describe that run, not this later harness commit.

For a replacement guest, run the repository's `scripts/linux-bootstrap.sh`
inside Ubuntu for Swift 6.4.0 and native dependencies, then `provision-extra.sh`
for headless display tools, Node and Playwright. The supplementary script selects
the latest Node 24 ARM64 archive, verifies its published SHA-256 and installs
Playwright 1.63.0's Chromium. It is not a complete VM/image provisioning script.
The measured run used Node 24.21.0; later provisioning may select a newer Node 24.

## Run and inspect

```sh
ssh scrimply-ci-tb '/usr/bin/python3 -u ~/ci/linux-vm/run-pilot.py'
```

The command starts the guarded guest, waits for SSH, runs `pilot-checks.sh`, saves
results under `results/<timestamp>`, then shuts down and releases its slots.
Check failures produce a failing exit status. Fixture generation must succeed
before test stages start; subsequent independent stages continue after an
individual failure and record exit codes in `pilot-results/stages.tsv`.
The known reverb failure remains a failure; no tolerance is relaxed.

Only run one launcher at a time. For manual work, run `run-vm.py` in the foreground
on the mini, use `guest-ssh` from another mini session, and end the launcher with
Ctrl-C when finished. SSH is forwarded only to `127.0.0.1:2224` on the mini.
There are no host-directory shares or GitHub credentials in the guest. Use
trusted source revisions; this persistent guest is not an untrusted PR sandbox.

With a manually launched guest running and no suite active, on the mini:

```sh
# Fresh compilation benchmark inside the guest.
~/ci/linux-vm/guest-ssh 'bash -s' < ~/ci/linux-vm/cold-build.sh
# Live guard check with a harmless simulated recorder-processing job.
/usr/bin/python3 ~/ci/linux-vm/test-guard.py
```

The cold build requires `.build-linux-cold` to be absent in the guest checkout;
archive or deliberately remove that scratch directory before repeating it.
Its logs stay in the guest's `pilot-results/` until explicitly copied back.

## Host admission and shutdown

The launcher reserves both Scrimply `ci` slots under
`/private/tmp/scrimply-heavy-slots/ci`, waiting up to ten minutes for admission.
Native host builds, Hello Mini jobs and recorder processing take priority:
guest CPUs pause and resume around them. Collection processes continue running.
This is cooperative five-second polling, not atomic exclusion for work outside
the semaphore. Changing the host slot count requires updating the launcher.

Non-normal host memory pressure, a pause over five minutes, cancellation or
parent-process loss, or a two-hour lifetime limit triggers shutdown. The
supervisor requests guest shutdown, waits up to 45 seconds and then terminates
an unresponsive QEMU process. A forced kill of the supervisor can bypass cleanup;
inspect the QEMU process and slot-owner PIDs before recovering stale state.
There is no launch service, automatic boot or recurring schedule.

## Evidence

- `results/<timestamp>/host.log`: admission, pause/resume and shutdown messages.
- `results/<timestamp>/checks.log`: fixture generation, Swift and integration checks.
- `results/<timestamp>/guest-results.tar`: JUnit, stage status, timing and guest memory.
- `logs/memory-*.jsonl`: host pressure, swap, QEMU RSS and `vm_stat` samples.
- `logs/bootstrap.log`: original Swift bootstrap and signature verification output.

The [evidence summary](../../docs/evidence/linux-ci-pilot-2026-09-30.json) retains
the September measurements; raw archives remain on the mini. Linux ARM64 software
graphics and virtual audio routes do not qualify physical audio/MIDI/GPU hardware,
x86-64, or the full package/install matrix. Existing GitHub-hosted checks remain
the release evidence.
