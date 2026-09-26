# Driftbox Linux preview

This archive contains the native GTK/GLES app, song/rack resources and Swift 6.4 runtime.
It targets the architecture and build distribution recorded in `manifest.json`; it is not a
universal Linux binary. Ubuntu 24.04 ARM64 is the first tested environment. GTK 4, Pango,
Mesa/EGL/GLES, PipeWire, ALSA and their system dependencies must be installed. The manifest lists
resolved system library names. No Swift compiler is needed to run it.

On Ubuntu 24.04, install the runtime and registration dependencies with:

```sh
sudo apt-get install libgtk-4-1 libegl1 libgles2 libegl-mesa0 libgl1-mesa-dri \
  libpipewire-0.3-0 libasound2t64 fonts-dejavu-core python3 desktop-file-utils shared-mime-info
```

Audio also needs a working PipeWire session on your desktop. The container test uses silent
mode and does not qualify physical audio or MIDI. Before extracting an archive, verify its
adjacent checksum file with `sha256sum -c Driftbox-*.tar.gz.sha256` (select one archive's checksum
when several are present). `manifest.json` records hashes for all bundled files, along with the
source commit and whether uncommitted changes were included, when supplied by the build script.

Extract the complete folder somewhere permanent, then run `./Driftbox`. For the Ubuntu VM's
native Wayland popup problem, run `./Driftbox --x11`. A song filename can follow; paths with
spaces are supported. Keep the bundles and `lib` beside the executable. The launcher preserves
the working directory so relative song filenames retain their meaning. Paths containing a
colon cannot be used for the bundle because ELF library search paths use colon separators.

Run `python3 install.py --x11` to add **Driftbox Linux Preview** to your app menu using XWayland,
or omit `--x11` to use GTK's normal display selection. This registers the extracted folder in
place; do not move/delete it while registered. After moving it, rerun the installer. Registration
uses `XDG_DATA_HOME` (default `~/.local/share`), requires `desktop-file-utils` and
`shared-mime-info`, and needs no sudo. It registers `.driftbox` song recognition and an Open With
handler. It does not set a default file association or claim generic JSON files.

Run `python3 install.py --uninstall` from the registered bundle to remove its menu/MIME entries.
The extracted bundle, documents and existing `org.driftbox.linux` preferences are retained.
A previous bundle's uninstaller refuses to remove a newer bundle's registration.

This remains a development preview: native Wayland menus, physical audio/MIDI latency and
hotplug, accessibility, other distributions/architectures and plug-in hosting are not release
qualified. CI has separate native ARM64 and x86-64 package jobs; each gates its artifact upload
on installation, upgrade, graphical launch and uninstall in a clean Ubuntu 24.04 runtime
container without Swift or development packages. This does not replace qualification on real
desktops before public distribution. The bundled licenses and manifest travel with the app;
this package is neither signed nor published.
