#!/usr/bin/env python3
"""Exercise real QMP pause/resume using a harmless simulated host-processing job."""
import runpy
import subprocess
import sys
import time
from pathlib import Path

module = runpy.run_path(str(Path(__file__).with_name('run-vm.py')))
qmp = module['qmp']
assert qmp('query-status')['running'], 'guest must start running'
dummy = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)',
                          'host-job.mjs', 'pilot-config', 'process', 'guard-validation'])
try:
    for _ in range(20):
        if not qmp('query-status')['running']:
            break
        time.sleep(1)
    else:
        raise AssertionError('host guard did not pause guest CPUs')
    print('PASS: guest CPUs paused for host processing')
finally:
    dummy.terminate()
    dummy.wait()
for _ in range(30):
    if qmp('query-status')['running']:
        break
    time.sleep(1)
else:
    raise AssertionError('host guard did not resume guest CPUs')
print('PASS: guest CPUs resumed after host processing')
