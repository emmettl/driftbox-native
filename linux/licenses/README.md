# Runtime notices

The packager also copies `usr/share/swift/LICENSE.txt` from the selected toolchain.
These additional files are from the matching Swift 6.4.0 source release:

- Dispatch.txt: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.4.0-RELEASE/LICENSE
- FoundationICU.txt: https://github.com/swiftlang/swift-foundation-icu/blob/f986d0728da0766cf81f371521b909d4a11681d2/LICENSE.md
- ICU-76.1.txt: https://github.com/unicode-org/icu/blob/release-76-1/LICENSE

The pinned Foundation ICU `icuSources/include/_foundation_unicode/uvernum.h` declares ICU 76.1.
Recheck these notices when upgrading the bundled runtime.
