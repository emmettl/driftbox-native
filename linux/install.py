#!/usr/bin/env python3
"""Register this extracted preview bundle in the current user's app menu."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

APP_ID = 'org.driftbox.linux.preview'
MARKER = 'X-Driftbox-Preview-Installer=1\n'
MIME = '''<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-driftbox-song">
    <comment>Driftbox song</comment>
    <sub-class-of type="application/json"/>
    <glob pattern="*.driftbox"/>
  </mime-type>
</mime-info>
'''


def desktop_quote(value):
    # Exec quoting is followed by desktop-entry string escaping, not shell parsing.
    if any(c in value for c in '\n\r\t%=:'):
        raise ValueError('The bundle path cannot contain tabs, newlines, %, = or :.')
    value = ''.join('\\' + c if c in '\\"`$' else c for c in value)
    return '"' + value.replace('\\', '\\\\') + '"'


def entry(root, x11):
    command = desktop_quote(str(root / 'Driftbox'))
    # Icon and custom keys use desktop string escaping without Exec quoting.
    plain = str(root).replace('\\', '\\\\')
    return f'''[Desktop Entry]
Type=Application
Name=Driftbox Linux Preview
Comment=Groovebox and modular instrument rack
Exec={command}{' --x11' if x11 else ''} %f
Icon={plain}/Driftbox.png
Terminal=false
Categories=AudioVideo;Audio;Midi;Music;
MimeType=application/x-driftbox-song;
StartupNotify=false
StartupWMClass={APP_ID}
{MARKER}X-Driftbox-Preview-Root={plain}
'''


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        try:
            f.write(text)
            f.flush()
            os.fchmod(f.fileno(), 0o644)
        except BaseException:
            temporary.unlink()
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def register(root, data, x11=False, uninstall=False):
    root = root.resolve()
    content = entry(root, x11)
    desktop = data / 'applications' / (APP_ID + '.desktop')
    mime = data / 'mime/packages' / (APP_ID + '.xml')
    for target in (desktop, mime):
        if target.is_symlink():
            raise ValueError(f'Refusing to replace a symlink: {target}')
    old = desktop.read_text() if desktop.exists() else None
    if old is not None and MARKER not in old.split('[Desktop Action', 1)[0]:
        raise ValueError(f'Existing desktop entry was not created by this installer: {desktop}')
    if mime.exists() and mime.read_text() != MIME:
        raise ValueError(f'Existing MIME entry has been modified: {mime}')
    if uninstall:
        owner = 'X-Driftbox-Preview-Root=' + str(root).replace('\\', '\\\\')
        if old is not None and owner not in old.splitlines():
            raise ValueError('A different preview bundle is registered; run its uninstaller.')
        # Without an owning desktop entry, do not remove shared registration state.
        if old is not None:
            desktop.unlink()
            mime.unlink(missing_ok=True)
    else:
        for name in ('Driftbox', 'driftbox-linux', 'Driftbox.png', 'manifest.json'):
            if not (root / name).is_file():
                raise ValueError(f'Incomplete bundle: missing {name}')
        atomic_write(mime, MIME)
        atomic_write(desktop, content)
    return desktop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--x11', action='store_true', help='Use XWayland for the Ubuntu VM menu workaround')
    parser.add_argument('--uninstall', action='store_true', help='Remove app-menu and MIME registration; keep bundle and preferences')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('Run as your desktop user, without sudo.')
    data = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
    if not data.is_absolute():
        parser.error('XDG_DATA_HOME must be absolute.')
    for command in ('update-desktop-database', 'update-mime-database'):
        if not shutil.which(command):
            parser.error(f'{command} is required (desktop-file-utils / shared-mime-info).')
    try:
        desktop = register(Path(__file__).resolve().parent, data, args.x11, args.uninstall)
        for command, folder in [('update-mime-database', data / 'mime'),
                                ('update-desktop-database', data / 'applications')]:
            if folder.exists():
                subprocess.run([command, str(folder)], check=True)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')
    print('Registration removed; bundle and preferences retained.' if args.uninstall else f'Installed app-menu entry: {desktop}')


if __name__ == '__main__':
    main()
