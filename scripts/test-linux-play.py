#!/usr/bin/env python3
"""Live PipeWire smoke test. Captures only this player's ports, never a microphone.

Run inside a signed-in Linux audio session after a release build:
  python3 scripts/test-linux-play.py .build-linux/release/driftbox-play
For the desktop, pass --desktop before the executable path and set the graphical display environment.
Needs pipewire-bin (pw-record, pw-link, pw-dump). Temporary capture is deleted on exit.
"""
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
arguments = sys.argv[1:]
DESKTOP = bool(arguments and arguments[0] == "--desktop")
if DESKTOP:
    arguments.pop(0)
PLAYER = Path(arguments[0]).resolve() if arguments else ROOT / ".build-linux/release/driftbox-play"
SONG = ROOT / "conformance/fixtures/documents/acid.song.json"
COMMAND = [str(PLAYER)] + (["--smoke-test"] if DESKTOP else []) + [str(SONG)]
ENV = {**os.environ, "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": "swift6"}


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=15, **kwargs)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def graph():
    result = run(["pw-dump"], env=ENV)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def node_for_pid(objects, pid):
    clients = {x["id"] for x in objects if x["type"] == "PipeWire:Interface:Client"
               and str(x.get("info", {}).get("props", {}).get("application.process.id")) == str(pid)}
    return next((x["id"] for x in objects if x["type"] == "PipeWire:Interface:Node"
                 and x.get("info", {}).get("props", {}).get("client.id") in clients), None)


def ports(objects, node, direction):
    return {x["info"]["props"].get("audio.channel"): x["id"] for x in objects
            if x["type"] == "PipeWire:Interface:Port"
            and str(x["info"]["props"].get("node.id")) == str(node)
            and x["info"]["props"].get("port.direction") == direction}


with tempfile.TemporaryDirectory(prefix="driftbox-play-test-") as directory:
    capture = Path(directory) / "capture.wav"
    with open(Path(directory) / "record.log", "w") as record_log:
        recorder = subprocess.Popen(
            ["pw-record", "--target=0", "--rate", "48000", "--channels", "2", "--format", "f32",
             "--properties", '{ node.name = "driftbox-test-capture" }', str(capture)],
            env=ENV, stdout=record_log, stderr=record_log)
        player = subprocess.Popen(COMMAND + ([] if DESKTOP else ["--seconds", "3"]), env=ENV,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 5
            while True:
                objects = graph()
                outputs = ports(objects, node_for_pid(objects, player.pid), "out")
                inputs = ports(objects, node_for_pid(objects, recorder.pid), "in")
                if all(c in outputs and c in inputs for c in ("FL", "FR")):
                    break
                assert time.monotonic() < deadline, "player/capture ports did not appear"
                time.sleep(.03)
            for channel in ("FL", "FR"):
                linked = run(["pw-link", str(outputs[channel]), str(inputs[channel])], env=ENV)
                assert linked.returncode == 0, linked.stderr
            output, _ = player.communicate(timeout=15)
            assert player.returncode == 0 and ("closed:" if DESKTOP else "stopped cleanly") in output, output
            print(output.strip())
            assert recorder.poll() is None, "recorder exited before capture was stopped"
        finally:
            stop(player)
            stop(recorder)
    # PipeWire 1.0.5 pw-cat returns 1 on SIGINT even after closing a valid recording:
    # https://github.com/PipeWire/pipewire/blob/1.0.5/src/tools/pw-cat.c#L1919
    # Require that it was alive before our stop, exited normally, and wrote valid audio below.
    assert recorder.returncode in (0, 1), ("capture failed", recorder.returncode,
                                          (Path(directory) / "record.log").read_text())
    data = capture.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", "not WAV"
    offset = 12
    chunks = {}
    while offset + 8 <= len(data):
        tag, size = struct.unpack_from("<4sI", data, offset)
        chunks[tag] = data[offset + 8:offset + 8 + size]
        offset += 8 + size + (size & 1)
    fmt, channels, rate = struct.unpack_from("<HHI", chunks[b"fmt "])
    assert (fmt, channels, rate) == (3, 2, 48000), (fmt, channels, rate)
    samples = [x[0] for x in struct.iter_unpack("<f", chunks[b"data"])]
    assert len(samples) > 48000, "too little captured audio"
    assert all(math.isfinite(x) for x in samples), "nonfinite samples"
    peaks = [max(map(abs, samples[channel::2])) for channel in (0, 1)]
    assert all(.01 < peak < 2 for peak in peaks), peaks
    print(f"Capture: {len(samples)//2} stereo frames at {rate} Hz, peaks {peaks}")

    if DESKTOP:
        sys.exit(0)

    # A signal must unwind the stream rather than abruptly exit or hang.
    for sig in (signal.SIGINT, signal.SIGTERM):
        player = subprocess.Popen(COMMAND, env=ENV, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True)
        try:
            time.sleep(.5)
            player.send_signal(sig)
            output, _ = player.communicate(timeout=7)
            assert player.returncode == 0 and "stopped cleanly" in output, output
        finally:
            stop(player)
        print(f"{sig.name}: clean shutdown")

    # Remove only this child player's own node to exercise a stream lost during playback.
    player = subprocess.Popen(COMMAND, env=ENV, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 3
        while True:
            node = node_for_pid(graph(), player.pid)
            if node is not None:
                break
            assert time.monotonic() < deadline, "player node did not appear"
            time.sleep(.03)
        time.sleep(.3)
        removed = run(["pw-cli", "destroy", str(node)], env=ENV)
        assert removed.returncode == 0, removed.stderr
        output, _ = player.communicate(timeout=7)
        assert player.returncode == 1 and "driftbox-play:" in output, output
        print("Lost stream: reported failure, exit 1")
    finally:
        stop(player)

    # No desktop service is stopped: point only the child at a nonexistent socket.
    result = run(COMMAND + ["--seconds", "1"], env={**ENV, "PIPEWIRE_REMOTE": "driftbox-no-such-server"})
    assert result.returncode == 1 and "driftbox-play:" in result.stderr, result
    print("Absent server: reported failure, exit 1")
    for value in ("nan", "inf", "-1", "nonsense"):
        result = run(COMMAND + ["--seconds", value], env=ENV)
        assert result.returncode == 1, result
    print("Invalid durations: rejected")
