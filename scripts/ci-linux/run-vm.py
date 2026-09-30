#!/usr/bin/env python3
"""On-demand Linux CI guest. Reserves both existing Scrimply CI slots.

Other host builds and recorder processing take priority: guest CPUs pause while
they run. Non-normal host memory pressure shuts this pilot down. No boot service.
"""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SLOTS = Path('/private/tmp/scrimply-heavy-slots/ci')
held = []
vm = None
stopping = False

def output(*args):
    return subprocess.check_output(args, text=True).strip()

def host_conflict():
    pressure = int(output('/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'))
    if pressure != 1:
        return f'host memory pressure {pressure}'
    for line in output('/bin/ps', '-axo', 'pid=,comm=,args=').splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        _, command, args = parts
        if Path(command).name in ('xcodebuild', 'swift-frontend', 'swift-build', 'swift-test'):
            return 'host native build'
        if 'host-job.mjs' in args and re.search(r'\s(process|analytics|retention)\s', args):
            return 'recorder processing'
        if 'hello-mini-runner' in command and Path(command).name == 'Runner.Worker':
            return 'Hello Mini build'
    return None

def acquire():
    SLOTS.mkdir(parents=True, exist_ok=True)
    for number in (1, 2):
        slot = SLOTS / f'slot.{number}'
        try:
            slot.mkdir()
        except FileExistsError:
            raise RuntimeError(f'CI slot busy: {slot}; retry when Mac CI is idle')
        held.append(slot)
        (slot / 'pid').write_text(str(os.getpid()))

def release():
    for slot in reversed(held):
        try:
            if (slot / 'pid').read_text() == str(os.getpid()):
                (slot / 'pid').unlink()
                slot.rmdir()
        except FileNotFoundError:
            pass

def qmp(command):
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(3)
            sock.connect(str(ROOT / 'qmp.sock'))
            stream = sock.makefile('rwb')
            stream.readline()
            for request in ('qmp_capabilities', command):
                stream.write((json.dumps({'execute': request}) + '\n').encode())
                stream.flush()
                while True:
                    reply = json.loads(stream.readline())
                    if 'error' in reply:
                        raise RuntimeError(str(reply['error']))
                    if 'return' in reply:
                        break
            return reply['return']
    except (OSError, ValueError) as error:
        raise RuntimeError(f'QMP {command}: {error}') from error

def powerdown():
    try:
        qmp('cont')
        qmp('system_powerdown')
    except RuntimeError as error:
        print(error, flush=True)

def on_signal(signum, frame):
    global stopping
    stopping = True

def main():
    global vm
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)
    parent = os.getppid()
    admission_deadline = time.monotonic() + 600
    announced = None
    while True:
        conflict = host_conflict()
        if not conflict:
            try:
                acquire()
                break
            except RuntimeError as error:
                release()
                held.clear()
                conflict = str(error)
        if stopping or os.getppid() != parent or time.monotonic() >= admission_deadline:
            raise RuntimeError(f'Pilot admission cancelled or timed out: {conflict}')
        if conflict != announced:
            print(f'Waiting for host: {conflict}', flush=True)
            announced = conflict
        time.sleep(5)
    (ROOT / 'logs').mkdir(exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    args = [
        '/opt/homebrew/bin/qemu-system-aarch64', '-name', 'linux-ci-pilot',
        '-machine', 'virt,accel=hvf', '-cpu', 'host', '-smp', '4', '-m', '4096',
        '-drive', 'if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd',
        '-drive', f'if=pflash,format=raw,file={ROOT}/images/efi-vars.fd',
        '-drive', f'if=virtio,format=qcow2,file={ROOT}/images/linux-ci.qcow2',
        '-drive', f'if=virtio,format=raw,readonly=on,file={ROOT}/images/seed.iso',
        '-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:2224-:22',
        '-device', 'virtio-net-pci,netdev=net0', '-device', 'virtio-rng-pci',
        '-device', 'virtio-serial-pci',
        '-chardev', f'socket,path={ROOT}/agent.sock,server=on,wait=off,id=agent',
        '-device', 'virtserialport,chardev=agent,name=org.qemu.guest_agent.0',
        '-display', 'none', '-serial', f'file:{ROOT}/logs/serial.log',
        '-monitor', 'none', '-qmp', f'unix:{ROOT}/qmp.sock,server=on,wait=off',
        '-pidfile', str(ROOT / 'qemu.pid'),
    ]
    with (ROOT / 'logs' / f'qemu-{stamp}.log').open('w') as err, \
         (ROOT / 'logs' / f'memory-{stamp}.jsonl').open('w', buffering=1) as metrics:
        vm = subprocess.Popen(args, stdout=err, stderr=err)
        print(f'QEMU pid {vm.pid}; 4 GiB, 4 vCPU; SSH localhost:2224', flush=True)
        started = time.monotonic()
        paused_at = None
        while vm.poll() is None:
            conflict = host_conflict()
            metrics.write(json.dumps({
                'time': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                'pressure': output('/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'),
                'swap': output('/usr/sbin/sysctl', '-n', 'vm.swapusage'),
                'qemu': output('/bin/ps', '-o', 'rss=,pcpu=', '-p', str(vm.pid)),
                'vm_stat': output('/usr/bin/vm_stat'),
                'conflict': conflict,
            }) + '\n')
            memory_conflict = conflict and conflict.startswith('host memory pressure')
            pause_expired = paused_at is not None and time.monotonic() - paused_at > 300
            orphaned = os.getppid() != parent
            if stopping or orphaned or memory_conflict or pause_expired or time.monotonic() - started > 7200:
                print(f'Shutting down: {conflict or "stop requested or two-hour limit"}', flush=True)
                powerdown()
                try:
                    vm.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    vm.terminate()
                    vm.wait(timeout=15)
                return 75 if conflict else 0
            if conflict and paused_at is None:
                qmp('stop')
                paused_at = time.monotonic()
                print(f'Guest CPUs paused for {conflict}', flush=True)
            elif not conflict and paused_at is not None:
                qmp('cont')
                paused_at = None
                print('Guest CPUs resumed; host heavy work finished', flush=True)
            time.sleep(5)
        return vm.returncode

if __name__ == '__main__':
    try:
        sys.exit(main())
    finally:
        if vm is not None and vm.poll() is None:
            powerdown()
            try:
                vm.wait(timeout=45)
            except subprocess.TimeoutExpired:
                vm.terminate()
                vm.wait(timeout=15)
        release()
