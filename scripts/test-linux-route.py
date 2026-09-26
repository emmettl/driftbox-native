#!/usr/bin/env python3
"""Run route integration tests on a private PipeWire server with silent virtual outputs.

Ubuntu 24.04 / WirePlumber 0.4 test harness. Hardware monitors are disabled in a temporary
configuration. The signed-in desktop's audio server and settings are never modified.
Includes a full server restart coordinated with the opt-in Swift ownership test.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def stop(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > deadline:
            raise RuntimeError("Timed out preparing private PipeWire session")
        time.sleep(.1)


version = subprocess.check_output(["wireplumber", "--version"], text=True)
if "0.4." not in version:
    raise SystemExit("This harness requires WirePlumber 0.4 (Ubuntu 24.04).")

with tempfile.TemporaryDirectory(prefix="driftbox-route-test-") as directory:
    root = Path(directory)
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    config = root / "wireplumber"
    shutil.copytree("/usr/share/wireplumber", config)
    main = config / "main.lua.d/90-enable-all.lua"
    text = main.read_text()
    for monitor in ("alsa", "v4l2", "libcamera"):
        text = text.replace(f"{monitor}_monitor.enable()", f"-- {monitor} disabled for isolated tests")
    main.write_text(text)
    wp_config = config / "wireplumber.conf"
    wp_config.write_text(wp_config.read_text().replace(
        "{ name = bluetooth.lua, type = config/lua }", "# Bluetooth disabled for isolated tests"))
    pw_config = root / "pipewire.conf"
    shutil.copyfile("/usr/share/pipewire/pipewire.conf", pw_config)
    env = {**os.environ,
           "XDG_RUNTIME_DIR": str(runtime), "PIPEWIRE_RUNTIME_DIR": str(runtime),
           "PIPEWIRE_REMOTE": "pipewire-0", "WIREPLUMBER_CONFIG_DIR": str(config),
           "XDG_STATE_HOME": str(root / "state"), "XDG_CONFIG_HOME": str(root / "config"),
           "XDG_CACHE_HOME": str(root / "cache"),
           "DRIFTBOX_TEST_PIPEWIRE": "1", "DRIFTBOX_TEST_RECOVERY_DIRECTORY": str(root),
           "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": "swift6"}
    processes = []
    test = None
    with open(root / "services.log", "w+") as log, open(root / "tests.log", "w+") as test_log:
        def launch(args):
            process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
            processes.append(process)
            return process

        def graph_ready():
            result = subprocess.run(["pw-dump"], env=env, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=2)
            return result.returncode == 0

        def start_server():
            launch(["pipewire", "-c", str(pw_config)])
            wait_for(lambda: (runtime / "pipewire-0").exists())
            wait_for(graph_ready)
            launch(["dbus-run-session", "--", "wireplumber", "-c", str(wp_config)])
            launch(["pw-cli", "-m", "create-node", "adapter",
                    '{ factory.name = support.null-audio-sink node.name = driftbox-test-default '
                    'node.description = "Driftbox silent test output" media.class = Audio/Sink '
                    'audio.position = [ FL FR ] priority.session = 2000 }'])

        def stop_server():
            for process in reversed(processes):
                stop(process)
            processes.clear()

        try:
            start_server()
            test = subprocess.Popen([str(ROOT / "scripts/linux-build.sh"), "test", "--filter", "PipeWireRouteTests"],
                                    cwd=ROOT, env=env, stdout=test_log, stderr=test_log, start_new_session=True)
            deadline = time.monotonic() + 180
            restarted = False
            down = False
            while test.poll() is None:
                stage_file = root / "stage"
                stage = stage_file.read_text() if stage_file.exists() else ""
                if stage == "ready" and not down:
                    stop_server()
                    down = True
                    print("Stopped the private test server", flush=True)
                elif stage == "offline" and not restarted:
                    start_server()
                    restarted = True
                    print("Restarted the private test server", flush=True)
                if time.monotonic() > deadline:
                    raise RuntimeError("Route tests timed out")
                time.sleep(.1)
            test_log.seek(0)
            print(test_log.read())
            assert test.returncode == 0, "Route tests failed"
            assert restarted and (root / "stage").read_text() == "recovered", "Server restart not verified"
            print("PASS: device choice, fallback, return, lost stream, and full server restart")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-10000:])
            test_log.flush()
            test_log.seek(0)
            print(test_log.read()[-10000:])
            raise
        finally:
            stop(test)
            stop_server()
