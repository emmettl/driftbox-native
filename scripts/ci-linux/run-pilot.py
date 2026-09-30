#!/usr/bin/env python3
"""Start the guarded guest, run pinned Driftbox checks, save results, power off."""
from pathlib import Path
import subprocess
import signal
import sys
import time

root = Path(__file__).resolve().parent
stamp = time.strftime('%Y%m%d-%H%M%S')
results = root / 'results' / stamp
results.mkdir(parents=True)
launcher = None
code = 1
def cancelled(signum, frame):
    raise SystemExit(128 + signum)
for sig in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, cancelled)
try:
    with (results / 'host.log').open('w', buffering=1) as host_log:
        launcher = subprocess.Popen([sys.executable, '-u', str(root / 'run-vm.py')], stdout=host_log, stderr=subprocess.STDOUT)
        print(f'Pilot results: {results}', flush=True)
        ready = False
        boot_deadline = time.monotonic() + 720
        while time.monotonic() < boot_deadline:
            if launcher.poll() is not None:
                raise RuntimeError((results / 'host.log').read_text())
            probe = subprocess.run([str(root / 'guest-ssh'), 'true'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if probe.returncode == 0:
                ready = True
                break
            time.sleep(2)
        if not ready:
            raise RuntimeError('Guest SSH did not become ready')
        with (root / 'pilot-checks.sh').open('rb') as checks, (results / 'checks.log').open('wb') as log:
            code = subprocess.run([str(root / 'guest-ssh'), 'bash -s'], stdin=checks, stdout=log, stderr=subprocess.STDOUT).returncode
        with (results / 'guest-results.tar').open('wb') as artifact:
            copied = subprocess.run([str(root / 'guest-ssh'), 'tar cf - -C ~/driftbox-native pilot-results'], stdout=artifact)
        if copied.returncode and code == 0:
            code = copied.returncode
        print(f'Checks exit code: {code}; logs: {results}', flush=True)
finally:
    if launcher is not None and launcher.poll() is None:
        launcher.terminate()
        try:
            launcher.wait(timeout=75)
        except subprocess.TimeoutExpired:
            print('VM supervisor did not finish shutdown; inspect it before another run.', file=sys.stderr)
            code = 1
sys.exit(code)
