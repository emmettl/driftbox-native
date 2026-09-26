#!/usr/bin/env python3
"""Build an Ubuntu .deb from a verified, trusted Driftbox preview bundle."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'driftbox-linux-preview'
APP_ID = 'org.driftbox.linux.preview'
PREFIX = Path('/usr/lib') / PACKAGE
MAINTAINER = 'Louis Emmett <emmettl@users.noreply.github.com>'


def digest(path, algorithm='sha256'):
    result = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify_bundle(bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    paths = list(bundle.rglob('*'))
    if any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in paths):
        raise ValueError('Bundle must contain only regular files and directories.')
    actual = {str(p.relative_to(bundle)) for p in paths if p.is_file()}
    if actual != set(manifest['files']) | {'manifest.json'}:
        raise ValueError('Bundle file inventory differs from the manifest.')
    for name, expected in manifest['files'].items():
        if digest(bundle / name) != expected:
            raise ValueError(f'Bundle checksum failed: {name}')
    if manifest['format'] != 1 or manifest['architecture'] not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported bundle format or architecture.')
    if (manifest['buildOS']['ID'], manifest['buildOS']['VERSION_ID']) != ('ubuntu', '24.04'):
        raise ValueError('The .deb preview requires an Ubuntu 24.04 build.')
    return manifest


def preview_version(manifest, epoch):
    version, build = manifest['version'], manifest['build']
    revision = manifest['source']['revision']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid application version/build.')
    if not re.fullmatch(r'[0-9a-f]{40}', revision or ''):
        raise ValueError('A source revision is required for preview versioning.')
    if not re.fullmatch(r'[0-9]+', epoch or ''):
        raise ValueError('Set SOURCE_DATE_EPOCH to the source commit timestamp.')
    dirty = manifest['source']['dirty']
    if not isinstance(dirty, bool):
        raise ValueError('Source dirty state is required.')
    return f'{version}~preview.{build}+git{int(epoch)}.{revision[:12]}' + ('.dirty' if dirty else '')


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def library_dependencies(stage, work):
    # Inspect every bundled ELF, including Swift's private runtime. Unversioned private
    # libraries need no external package, but missing public-library metadata is fatal.
    # Do not use --ignore-missing-info: that could hide an undeclared system dependency.
    app = stage / PREFIX.relative_to('/')
    binaries = [app / 'driftbox-linux', *sorted((app / 'lib').glob('*.so'))]
    env = dict(os.environ, LC_ALL='C')
    env.pop('LD_LIBRARY_PATH', None)
    result = subprocess.run(['dpkg-shlibdeps', '-O', f'-l{app / "lib"}', f'-S{stage}',
                             *[f'-e{p}' for p in binaries]], cwd=work, env=env,
                            text=True, stdout=subprocess.PIPE, check=True)
    lines = result.stdout.splitlines()
    if len(lines) != 1 or not lines[0].startswith('shlibs:Depends='):
        raise ValueError('Unexpected dpkg-shlibdeps output.')
    return lines[0].removeprefix('shlibs:Depends=')


def build_deb(bundle, output, epoch):
    host_os = platform.freedesktop_os_release()
    if (host_os.get('ID'), host_os.get('VERSION_ID')) != ('ubuntu', '24.04'):
        raise ValueError('Build the preview .deb on Ubuntu 24.04.')
    manifest = verify_bundle(bundle)
    version = preview_version(manifest, epoch)
    arch = {'arm64': 'arm64', 'x86_64': 'amd64'}[manifest['architecture']]
    host = subprocess.check_output(['dpkg', '--print-architecture'], text=True).strip()
    if arch != host:
        raise ValueError(f'Build the {arch} package on a native {arch} Ubuntu builder, not {host}.')
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f'{PACKAGE}_{version}_{arch}.deb'
    if destination.exists():
        raise ValueError(f'Output already exists: {destination}')
    with tempfile.TemporaryDirectory(prefix='.linux-deb-', dir=output) as temporary:
        work = Path(temporary)
        stage = work / 'debian' / PACKAGE
        control = stage / 'DEBIAN'
        control.mkdir(parents=True)
        write(work / 'debian/control', f'Source: {PACKAGE}\nSection: sound\nPriority: optional\n'
              f'Maintainer: {MAINTAINER}\n\nPackage: {PACKAGE}\nArchitecture: any\nDescription: Native Driftbox preview\n')
        app = stage / PREFIX.relative_to('/')
        shutil.copytree(bundle, app)
        write(stage / 'usr/bin' / PACKAGE, '#!/bin/sh\nexec /usr/lib/driftbox-linux-preview/Driftbox "$@"\n', 0o755)
        desktop = stage / 'usr/share/applications' / (APP_ID + '.desktop')
        write(desktop, f'''[Desktop Entry]
Type=Application
Name=Driftbox Linux Preview
Comment=Groovebox and modular instrument rack
Exec={PACKAGE} --x11 %f
Icon={APP_ID}
Terminal=false
Categories=AudioVideo;Audio;Midi;Music;
MimeType=application/x-driftbox-song;
StartupNotify=false
StartupWMClass={APP_ID}
''')
        subprocess.run(['desktop-file-validate', str(desktop)], check=True)
        spec = importlib.util.spec_from_file_location('driftbox_install', ROOT / 'linux/install.py')
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        write(stage / 'usr/share/mime/packages' / (APP_ID + '.xml'), installer.MIME)
        icon = stage / 'usr/share/icons/hicolor/256x256/apps' / (APP_ID + '.png')
        icon.parent.mkdir(parents=True)
        shutil.copy2(bundle / 'Driftbox.png', icon)
        doc = stage / 'usr/share/doc' / PACKAGE
        write(doc / 'copyright', (ROOT / 'LICENSE').read_text() +
              f'\nBundled Swift and third-party notices: {PREFIX}/licenses/\n')
        shutil.copy2(ROOT / 'linux/packaging/README-deb.md', doc / 'README.md')
        generated = library_dependencies(stage, work)
        # These runtime/data dependencies do not all appear as linked ELF symbols.
        # The explicit GTK floor is stronger than the current symbol-derived 4.12 floor.
        depends = generated + ', libgtk-4-1 (>= 4.14), libegl-mesa0, libgl1-mesa-dri, fonts-dejavu-core, desktop-file-utils, shared-mime-info, hicolor-icon-theme, xwayland'
        files = sorted(p for p in stage.rglob('*') if p.is_file() and not p.is_relative_to(control))
        size = (sum(p.stat().st_size for p in files) + 1023) // 1024
        write(control / 'control', f'''Package: {PACKAGE}
Version: {version}
Architecture: {arch}
Maintainer: {MAINTAINER}
Section: sound
Priority: optional
Installed-Size: {size}
Depends: {depends}
Homepage: https://github.com/emmettl/driftbox-native
Description: Native Driftbox groovebox and modular instrument rack (preview)
 Ubuntu 24.04 preview with a private Swift runtime. The desktop launcher uses
 X11/XWayland while native Wayland menu support is being qualified.
''')
        write(control / 'md5sums', ''.join(f'{digest(p, "md5")}  {p.relative_to(stage)}\n' for p in files))
        # Existing desktop/MIME/icon packages own the file triggers. No maintainer
        # scripts, ldconfig hooks, services, or access to users' home directories.
        env = dict(os.environ, SOURCE_DATE_EPOCH=epoch)
        temporary_deb = work / destination.name
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(stage), str(temporary_deb)],
                       env=env, check=True)
        temporary_deb.rename(destination)
    destination.with_suffix('.deb.sha256').write_text(f'{digest(destination)}  {destination.name}\n')
    print(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        build_deb(args.bundle.resolve(), args.output.resolve(), os.environ.get('SOURCE_DATE_EPOCH'))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
