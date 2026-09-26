# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

## What is signed

Driftbox for Windows, as the [release workflow](.github/workflows/release.yml) builds it on
GitHub's own runners from this repository's source, and nothing else:

- `Driftbox.exe`, the program;
- `DriftboxVST3Scan.exe`, which asks each VST 3 plug-in Driftbox finds what it holds, in a process of
  its own;
- `Driftbox-<version>-setup-x64.exe`, the installer made from them.

Each is held to the product name and the release's version it carries, as the
[artifact configurations](.signpath/artifact-configurations) say. The Swift and Visual C++ runtime
DLLs that ship beside the program are not this project's, and are not signed by it. Neither is
the installer's uninstaller, which Inno Setup writes when it installs.

## Team

- Committers and reviewers: [emmettl](https://github.com/emmettl)
- Approvers: [emmettl](https://github.com/emmettl)

Every signing request is approved by hand in SignPath, by an approver, for a build of a tag whose
version is the one in [`scripts/version.env`](scripts/version.env).

## Privacy

This program will not transfer any information to other networked systems unless specifically
requested by the user or the person installing or operating it.

VST 3 plug-ins that a person installs and loads into Driftbox are programs of their own, and what
they do is up to them.
