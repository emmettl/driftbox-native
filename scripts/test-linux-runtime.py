#!/usr/bin/env python3
"""Qualify one trusted preview archive inside the isolated Ubuntu runtime container."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, **kwargs):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=90, **kwargs)
    print(result.stdout, end='', flush=True)
    require(result.returncode == 0, f'Command failed ({result.returncode}): {args}')
    return result.stdout


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_files(bundle, manifest):
    actual = {str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file()}
    require(actual == set(manifest['files']) | {'manifest.json'}, 'Unexpected or missing bundle files')
    for name, expected in manifest['files'].items():
        require(digest(bundle / name) == expected, f'Bundle checksum failed: {name}')


def main():
    require(os.geteuid() != 0, 'Run as the container desktop user, without root privileges')
    for command in ('swift', 'swiftc', 'clang', 'gcc', 'cc', 'pkg-config'):
        require(shutil.which(command) is None, f'Development tool leaked into runtime: {command}')
    packages = subprocess.check_output(
        ['dpkg-query', '-W', '-f=${binary:Package} ${db:Status-Status}\n'], text=True, timeout=30)
    installed = [line.split()[0].split(':')[0] for line in packages.splitlines() if line.endswith(' installed')]
    require(not any(name.endswith('-dev') or name.startswith('swift') for name in installed),
            'Development packages leaked into runtime')
    archives = list(Path(sys.argv[1]).glob('*.tar.gz'))
    require(len(archives) == 1, 'Expected exactly one package archive')
    archive = archives[0]
    require(archive.with_suffix('.gz.sha256').read_text() == f'{digest(archive)}  {archive.name}\n',
            'Archive checksum failed')
    home = Path.home()
    apps = home / 'Applications with spaces'
    apps.mkdir()
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        require(all(member.isfile() or member.isdir() for member in members), 'Unexpected archive member type')
        require({Path(member.name).parts[0] for member in members} == {archive.name[:-7]},
                'Expected a single bundle root')
        tar.extractall(apps, filter='data')
    original = apps / archive.name[:-7]
    manifest = json.loads((original / 'manifest.json').read_text())
    require(manifest['architecture'] == {'aarch64': 'arm64', 'x86_64': 'x86_64'}[platform.machine()],
            'Archive architecture does not match the native runtime')
    require(manifest['buildOS']['ID'] == 'ubuntu' and manifest['buildOS']['VERSION_ID'] == '24.04',
            'Unexpected distribution baseline')
    require(re.fullmatch('[0-9a-f]{40}', manifest['source']['revision'] or '') is not None,
            'Missing source revision')
    require(isinstance(manifest['source']['dirty'], bool), 'Missing source dirty state')
    verify_files(original, manifest)
    print(f'Verified {len(manifest["files"])} bundle files and archive checksum', flush=True)
    env = dict(os.environ)
    env.pop('LD_LIBRARY_PATH', None)
    env.pop('LD_PRELOAD', None)
    env['XDG_DATA_HOME'] = str(home / '.local/share')
    env['XDG_CONFIG_HOME'] = str(home / '.config')
    env['XDG_RUNTIME_DIR'] = str(home / 'runtime')
    Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
    desktop = Path(env['XDG_DATA_HOME']) / 'applications/org.driftbox.linux.preview.desktop'
    mime = Path(env['XDG_DATA_HOME']) / 'mime/packages/org.driftbox.linux.preview.xml'
    preferences = Path(env['XDG_CONFIG_HOME']) / 'org.driftbox.linux.plist'
    preferences.parent.mkdir(parents=True)
    preferences.write_bytes(b'preferences must survive registration changes')
    document = home / 'Keep this song.driftbox'
    document.write_bytes(b'document must survive registration changes')

    def register(bundle, *args):
        return run(['python3', str(bundle / 'install.py'), *args], env=env)

    register(original, '--x11')
    run(['desktop-file-validate', str(desktop)])
    require(f'Exec="{original}/Driftbox" --x11 %f' in desktop.read_text(), 'Incorrect desktop command')
    require('application/x-driftbox-song' in mime.read_text(), 'Missing song MIME registration')
    require((mime.parent.parent / 'mime.cache').is_file(), 'MIME cache was not generated')

    # A second extracted location exercises upgrades and ownership without replacing the first.
    upgraded = apps / 'Updated preview'
    shutil.copytree(original, upgraded)
    register(upgraded, '--x11')
    entry = desktop.read_bytes()
    old = subprocess.run(['python3', str(original / 'install.py'), '--uninstall'], env=env,
                         text=True, capture_output=True, timeout=30)
    require(old.returncode != 0 and 'different preview bundle' in old.stderr,
            'Old bundle uninstaller should refuse a newer registration')
    require(desktop.read_bytes() == entry and mime.is_file(), 'Old uninstaller damaged registration')
    shutil.rmtree(original)
    verify_files(upgraded, manifest)
    run(['desktop-file-validate', str(desktop)])
    require(f'Exec="{upgraded}/Driftbox" --x11 %f' in desktop.read_text(), 'Upgrade did not relocate launcher')

    closure = run(['ldd', str(upgraded / 'driftbox-linux')],
                  env=dict(env, LD_LIBRARY_PATH=str(upgraded / 'lib')))
    require('not found' not in closure, 'Unresolved runtime dependency')
    resolved = dict(re.findall(r'^\s*(\S+) => (.+?) \(0x', closure, re.M))
    for name in manifest['bundledLibraries']:
        require(resolved.get(name) == str(upgraded / 'lib' / name), f'{name} escaped the bundle')
    smoke = run(['dbus-run-session', '--', 'xvfb-run', '-a', str(upgraded / 'Driftbox'),
                 '--x11', '--silent', '--smoke-test'], env=env)
    require('five deferred requests cancelled exactly once; queued notices disposed' in smoke,
            'Native dialog check did not complete')
    require(re.search(r'closed: [1-9][0-9]* GUI frames, 0 audio frames', smoke) is not None,
            'Packaged desktop smoke did not complete')
    register(upgraded, '--uninstall')
    register(upgraded, '--uninstall')  # Idempotent after removal.
    require(not desktop.exists() and not mime.exists(), 'Registration survived uninstall')
    require(preferences.read_bytes() == b'preferences must survive registration changes', 'Preferences changed')
    require(document.read_bytes() == b'document must survive registration changes', 'Document changed')
    verify_files(upgraded, manifest)
    print('PASS: clean Ubuntu runtime, archive integrity, installation, upgrade, relocation, graphical launch, uninstall', flush=True)


if __name__ == '__main__':
    main()
