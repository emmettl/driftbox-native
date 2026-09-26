# Driftbox Linux Preview for Ubuntu 24.04

Install the package matching your CPU (`amd64` or `arm64`):

```sh
sha256sum -c driftbox-linux-preview_*.deb.sha256
sudo apt install ./driftbox-linux-preview_VERSION_ARCH.deb
```

Select the matching checksum/package explicitly if the directory contains several versions.
APT installs the system dependencies. No Swift compiler is required. Launch **Driftbox Linux
Preview** from your app menu, or run `driftbox-linux-preview --x11`. The app-menu entry uses
X11/XWayland; native Wayland menus are still being qualified. Audio needs a running PipeWire
session. Physical audio/MIDI and accessibility remain preview limitations.

Upgrade by installing the newer `.deb` with the same APT command. Preview versions include
the shared application version/build, source commit timestamp, and commit ID; an eventual
release with the same application version sorts after its previews. Locally modified builds
carry a `.dirty` suffix. These are development artifacts, not a signed APT repository or an
automatic update service.

If you previously registered an extracted archive, first run its
`python3 /path/to/old/bundle/install.py --uninstall` **as your desktop user**. A per-user menu
entry otherwise takes precedence over this system package's entry. Keep the old bundle until
you have removed its registration. The package never alters per-user registrations or defaults.

Remove the package with `sudo apt remove driftbox-linux-preview`, or purge package metadata
with `sudo apt purge driftbox-linux-preview`. Both retain your documents and preferences.
The executable, private libraries and resources live in `/usr/lib/driftbox-linux-preview`;
APT owns these files. Do not run the archive's `install.py` for this system installation.

Preview tracking, source changes and validation:
https://github.com/emmettl/driftbox-native/pull/186
