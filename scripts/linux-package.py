#!/usr/bin/env python3
"""Package a trusted local Linux build. Does not build, install, sign or upload it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLES = ('DriftboxKit_DriftboxSession.bundle', 'DriftboxKit_DriftboxRackSession.bundle')


def dependencies(program, runtime):
    env = dict(os.environ, LC_ALL='C', LD_LIBRARY_PATH=str(runtime))
    result = subprocess.run(['ldd', str(program)], env=env, text=True, capture_output=True, check=True)
    if 'not found' in result.stdout:
        raise ValueError('Unresolved shared libraries:\n' + result.stdout)
    found = {}
    for line in result.stdout.splitlines():
        match = re.match(r'\s*(\S+) => (.+?) \(0x', line)
        if match:
            found[match[1]] = Path(match[2]).resolve(strict=True)
    if 'libswiftCore.so' not in found or 'lib_FoundationICU.so' not in found:
        raise ValueError('Expected the Swift/Foundation runtime dependency closure.')
    return found


def icon_png(ico):
    data = ico.read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data)
    if reserved or kind != 1:
        raise ValueError('Invalid ICO header')
    images = []
    for index in range(count):
        width, height, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * index)
        png = data[offset:offset + size]
        if png.startswith(b'\x89PNG\r\n\x1a\n') and len(png) == size:
            images.append(((width or 256) * (height or 256), png))
    if not images:
        raise ValueError('No PNG image in the committed Windows icon')
    return max(images, key=lambda item: item[0])[1]


def sha256(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def package(build, toolchain, output, source_revision=None, source_dirty=None):
    if source_revision is not None and not re.fullmatch(r'[0-9a-f]{40}', source_revision):
        raise ValueError('Source revision must be a full Git SHA-1 commit ID.')
    program = build / 'driftbox-linux'
    with program.open('rb') as file:
        header = file.read(20)
    if len(header) != 20:
        raise ValueError('Truncated ELF header.')
    machine = struct.unpack_from('<H', header, 18)[0]
    arch = {183: 'arm64', 62: 'x86_64'}.get(machine)
    if header[:6] != b'\x7fELF\x02\x01' or arch is None:
        raise ValueError('Expected a little-endian ARM64 or x86-64 Linux executable.')
    runtime = toolchain / 'usr/lib/swift/linux'
    libraries = dependencies(program, runtime)
    bundled = {name: path for name, path in libraries.items() if path.is_relative_to(runtime.resolve())}
    if not all(libraries[name] == bundled.get(name) for name in libraries
               if name.startswith(('libswift', 'libFoundation', 'lib_Foundation'))
               or name in ('libdispatch.so', 'libBlocksRuntime.so')):
        raise ValueError('Runtime dependencies resolved outside the selected toolchain.')
    # The vendored supplemental notices correspond to this toolchain version only.
    version = subprocess.check_output([str(toolchain / 'usr/bin/swiftc'), '--version'], text=True).splitlines()[0]
    if not re.search(r'\bSwift version 6\.4(?:\.0)?(?: |$)', version):
        raise ValueError('Requalify runtime notices before packaging another Swift version.')
    for bundle in BUNDLES:
        if not (build / bundle).is_dir():
            raise ValueError(f'Missing resource bundle: {bundle}')
    release = dict(re.findall(r'^(DRIFTBOX_\w+)=(.+)$', (ROOT / 'scripts/version.env').read_text(), re.M))
    name = f'Driftbox-{release["DRIFTBOX_VERSION"]}-preview-{arch}-{sha256(program)[:12]}'
    output.mkdir(parents=True, exist_ok=True)
    folder, archive = output / name, output / (name + '.tar.gz')
    if folder.exists() or archive.exists():
        raise ValueError(f'Output already exists: {name}. Choose another --output directory.')
    with tempfile.TemporaryDirectory(prefix='.linux-package-', dir=output) as temporary:
        stage = Path(temporary) / name
        stage.mkdir()
        shutil.copy2(program, stage / program.name)
        (stage / 'lib').mkdir()
        for soname, path in sorted(bundled.items()):
            shutil.copy2(path, stage / 'lib' / soname)
        for bundle in BUNDLES:
            shutil.copytree(build / bundle, stage / bundle)
        for filename in ('Driftbox', 'install.py', 'README.md'):
            shutil.copy2(ROOT / 'linux' / filename, stage / filename)
        for filename in ('Driftbox', 'install.py', 'driftbox-linux'):
            (stage / filename).chmod(0o755)
        (stage / 'Driftbox.png').write_bytes(icon_png(ROOT / 'windows/Driftbox.ico'))
        shutil.copytree(ROOT / 'linux/licenses', stage / 'licenses')
        shutil.copy2(ROOT / 'LICENSE', stage / 'licenses/Driftbox.txt')
        shutil.copy2(toolchain / 'usr/share/swift/LICENSE.txt', stage / 'licenses/Swift.txt')
        manifest = {
            'format': 1, 'version': release['DRIFTBOX_VERSION'], 'build': release['DRIFTBOX_BUILD'],
            'architecture': arch, 'swift': version, 'resources': list(BUNDLES),
            'source': {'revision': source_revision, 'dirty': source_dirty},
            'bundledLibraries': sorted(bundled),
            'systemLibraries': sorted(set(libraries) - set(bundled)),
            'buildOS': platform.freedesktop_os_release(),
            'files': {str(p.relative_to(stage)): sha256(p) for p in sorted(stage.rglob('*')) if p.is_file()},
        }
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        temp_archive = Path(temporary) / archive.name
        with tarfile.open(temp_archive, 'w:gz') as tar:
            tar.add(stage, arcname=name)
        stage.rename(folder)
        temp_archive.rename(archive)
    archive.with_suffix(archive.suffix + '.sha256').write_text(f'{sha256(archive)}  {archive.name}\n')
    print(archive)
    print(f'{len(bundled)} bundled runtime libraries; {archive.stat().st_size / 1048576:.1f} MiB compressed')
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / '.build-linux/release')
    parser.add_argument('--toolchain', type=Path, default=Path.home() / '.local/share/driftbox-toolchains/swift-6.4.0-RELEASE')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/linux')
    parser.add_argument('--source-revision', help='Full Git commit ID supplied by the build orchestrator')
    parser.add_argument('--source-dirty', choices=('true', 'false'), help='Whether the build includes uncommitted changes')
    args = parser.parse_args()
    if platform.system() != 'Linux':
        parser.error('Run in Linux against a trusted local build; ldd inspects its runtime closure.')
    try:
        package(args.build_dir.resolve(), args.toolchain.resolve(), args.output.resolve(),
                args.source_revision, None if args.source_dirty is None else args.source_dirty == 'true')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
