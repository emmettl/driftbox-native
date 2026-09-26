#!/usr/bin/env python3
"""Test trusted .deb artifacts in a disposable root-owned Ubuntu container only."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PACKAGE = 'driftbox-linux-preview'
APP_ID = 'org.driftbox.linux.preview'
APP = Path('/usr/lib') / PACKAGE
DESKTOP = Path('/usr/share/applications') / (APP_ID + '.desktop')
MIME = Path('/usr/share/mime/packages') / (APP_ID + '.xml')
ICON = Path('/usr/share/icons/hicolor/256x256/apps') / (APP_ID + '.png')
TEST_HOME = Path('/home/tester')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, **kwargs):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=180, **kwargs)
    print(result.stdout, end='', flush=True)
    require(result.returncode == 0, f'Command failed ({result.returncode}): {args}')
    return result.stdout


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def installed(name):
    result = subprocess.run(['dpkg-query', '-W', '-f=${Status}', name], text=True, capture_output=True)
    return result.returncode == 0 and result.stdout == 'install ok installed'


def verify_install():
    require(installed(PACKAGE), 'Package is not configured')
    require(run(['dpkg', '--verify', PACKAGE]).strip() == '', 'dpkg payload checks failed')
    manifest = json.loads((APP / 'manifest.json').read_text())
    actual = {str(p.relative_to(APP)) for p in APP.rglob('*') if p.is_file()}
    require(actual == set(manifest['files']) | {'manifest.json'}, 'Bundle inventory changed')
    for name, expected in manifest['files'].items():
        require(digest(APP / name) == expected, f'Installed payload checksum failed: {name}')
    run(['desktop-file-validate', str(DESKTOP)])
    require(f'Exec={PACKAGE} --x11 %f' in DESKTOP.read_text(), 'Wrong app-menu command')
    require(ICON.is_file() and MIME.is_file(), 'Missing desktop integration files')
    require(APP_ID + '.desktop' in Path('/usr/share/applications/mimeinfo.cache').read_text(),
            'Desktop database trigger did not register the handler')
    require('application/x-driftbox-song:*.driftbox' in Path('/usr/share/mime/globs2').read_text(),
            'MIME trigger did not register the song extension')
    env = ['env', 'HOME=/home/tester', 'XDG_CONFIG_HOME=/home/tester/smoke-config',
           'XDG_DATA_HOME=/home/tester/smoke-data', 'GTK_A11Y=none',
           'GSETTINGS_BACKEND=memory', 'LIBGL_ALWAYS_SOFTWARE=1']
    closure = run(['runuser', '-u', 'tester', '--', *env, f'LD_LIBRARY_PATH={APP}/lib',
                   'ldd', str(APP / 'driftbox-linux')])
    require('not found' not in closure, 'Missing runtime libraries after APT install')
    resolved = dict(re.findall(r'^\s*(\S+) => (.+?) \(0x', closure, re.M))
    for name in manifest['bundledLibraries']:
        require(resolved.get(name) == str(APP / 'lib' / name), 'Swift runtime escaped the private directory')
    smoke = run(['runuser', '-u', 'tester', '--', *env, 'dbus-run-session', '--', 'xvfb-run', '-a',
                 PACKAGE, '--x11', '--silent', '--smoke-test'])
    require('five deferred requests cancelled exactly once; queued notices disposed' in smoke,
            'Native dialog smoke did not complete')
    require(re.search(r'closed: [1-9][0-9]* GUI frames, 0 audio frames', smoke), 'No rendered GUI frames')


def verify_removed():
    for path in (APP, DESKTOP, MIME, ICON, Path('/usr/bin') / PACKAGE, Path('/usr/share/doc') / PACKAGE):
        require(not path.exists(), f'Package payload survived removal: {path}')
    require(APP_ID + '.desktop' not in Path('/usr/share/applications/mimeinfo.cache').read_text(),
            'Removed app remains in the desktop database')
    require('application/x-driftbox-song:*.driftbox' not in Path('/usr/share/mime/globs2').read_text(),
            'Removed song handler remains in the MIME database')


def main():
    require(os.geteuid() == 0 and Path('/.dockerenv').exists(), 'Run only inside a disposable Docker container')
    require(not installed(PACKAGE) and not installed('libgtk-4-1'), 'Runtime baseline already has the app/GTK')
    artifacts = list(Path(sys.argv[1]).glob('*.deb'))
    require(len(artifacts) == 1, 'Expected exactly one deb artifact')
    deb = artifacts[0]
    require(deb.with_suffix('.deb.sha256').read_text() == f'{digest(deb)}  {deb.name}\n', 'Deb checksum failed')
    arch = run(['dpkg-deb', '-f', str(deb), 'Architecture']).strip()
    require(arch == run(['dpkg', '--print-architecture']).strip(), 'Wrong architecture')
    depends = run(['dpkg-deb', '-f', str(deb), 'Depends'])
    require('libgtk-4-1 (>= 4.14)' in depends, 'Missing explicit GTK runtime floor')
    # User registrations take precedence over system entries. Package installation must
    # leave these, documents, preferences and chosen default handlers alone.
    sentinels = {}
    for relative in ('Keep my song.driftbox', '.config/org.driftbox.linux.plist',
                     '.config/mimeapps.list', f'.local/share/applications/{APP_ID}.desktop',
                     f'.local/share/mime/packages/{APP_ID}.xml'):
        path = TEST_HOME / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        content = f'User-owned content: {relative}\n'.encode()
        path.write_bytes(content)
        sentinels[path] = content
    shutil.chown(TEST_HOME, user='tester', group='tester')
    for path in TEST_HOME.rglob('*'):
        shutil.chown(path, user='tester', group='tester')

    def unchanged():
        for path, content in sentinels.items():
            require(path.read_bytes() == content and path.stat().st_uid == 10001, f'User data changed: {path}')

    # Docker disables networking. Allow APT's file acquisition for the local .deb:
    # --no-download also suppresses that step and breaks local-file installation.
    apt = ['apt-get', '-y', '--no-install-recommends']
    run([*apt, 'install', str(deb)])
    verify_install()
    unchanged()
    run([*apt, 'remove', PACKAGE])
    verify_removed()
    unchanged()
    # Construct a lower-version fixture from the same payload, with an obsolete owned
    # file. It is test-only: never uploaded. APT must upgrade and remove the obsolete file.
    with tempfile.TemporaryDirectory(prefix='driftbox-deb-upgrade-') as temporary:
        work = Path(temporary)
        root = work / 'previous'
        run(['dpkg-deb', '--raw-extract', str(deb), str(root)])
        control = root / 'DEBIAN/control'
        text = control.read_text()
        version = re.search(r'^Version: (.+)$', text, re.M).group(1)
        previous = version + '~upgrade-test'
        run(['dpkg', '--compare-versions', previous, 'lt', version])
        control.write_text(text.replace(f'Version: {version}\n', f'Version: {previous}\n'))
        obsolete = Path('usr/share/doc') / PACKAGE / 'obsolete-upgrade-fixture'
        (root / obsolete).write_text('old version only\n')
        old_deb = work / 'previous.deb'
        run(['dpkg-deb', '--root-owner-group', '--build', str(root), str(old_deb)])
        run([*apt, 'install', str(old_deb)])
        require((Path('/') / obsolete).exists(), 'Previous version fixture was not installed')
        run([*apt, 'install', str(deb)])
        require(not (Path('/') / obsolete).exists(), 'Upgrade left an obsolete package file')
        require(run(['dpkg-query', '-W', '-f=${Version}', PACKAGE]).strip() == version, 'Upgrade version mismatch')
        verify_install()
        unchanged()
    run([*apt, 'purge', PACKAGE])
    verify_removed()
    unchanged()
    require(run(['dpkg', '--audit']).strip() == '', 'dpkg reports incomplete package state')
    for command in ('swift', 'swiftc', 'gcc', 'cc', 'clang', 'pkg-config'):
        require(shutil.which(command) is None, f'Development tool leaked into runtime: {command}')
    packages = run(['dpkg-query', '-W', '-f=${binary:Package} ${db:Status-Status}\n'])
    installed_names = [line.split()[0].split(':')[0] for line in packages.splitlines() if line.endswith(' installed')]
    require(not any(name.endswith('-dev') or name.startswith('swift') for name in installed_names),
            'Development packages leaked into runtime')
    print('PASS: deb dependency installation offline, unprivileged GUI, upgrade, obsolete-file removal, remove/purge, user-data preservation', flush=True)


if __name__ == '__main__':
    main()
