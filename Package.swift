// swift-tools-version: 6.4
import PackageDescription

// DriftboxDSP, DriftboxSeq, DriftboxEngine and DriftboxRack are held to a rule the compiler can check: no
// Foundation, no existentials, no reflection, nothing that needs a runtime or a platform.
// `scripts/check-constrained.sh` compiles them as Embedded Swift to prove it. It is a lint here,
// not a product, though it is also what keeps a WebAssembly build of the same sources possible.

let package = Package(
  name: "DriftboxKit",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "DriftboxDSP", targets: ["DriftboxDSP"]),
    .library(name: "DriftboxSeq", targets: ["DriftboxSeq"]),
    .library(name: "DriftboxEngine", targets: ["DriftboxEngine"]),
    .library(name: "DriftboxRack", targets: ["DriftboxRack"]),
    .library(name: "DriftboxDocument", targets: ["DriftboxDocument"]),
    .library(name: "DriftboxHost", targets: ["DriftboxHost"]),
    .library(name: "DriftboxHostWindows", targets: ["DriftboxHostWindows"]),
    .library(name: "DriftboxHostAndroid", targets: ["DriftboxHostAndroid"]),
    .library(name: "DriftboxGPU", targets: ["DriftboxGPU"]),
    .library(name: "DriftboxGPUD3D11", targets: ["DriftboxGPUD3D11"]),
    .library(name: "DriftboxShell", targets: ["DriftboxShell"]),
    .library(name: "DriftboxGPUGLES", targets: ["DriftboxGPUGLES"]),
    .library(name: "DriftboxWin32", targets: ["DriftboxWin32"]),
    .library(name: "DriftboxText", targets: ["DriftboxText"]),
    .library(name: "DriftboxTextWindows", targets: ["DriftboxTextWindows"]),
    .library(name: "DriftboxCanvas", targets: ["DriftboxCanvas"]),
    .library(name: "DriftboxScenes", targets: ["DriftboxScenes"]),
    .library(name: "DriftboxSession", targets: ["DriftboxSession"]),
    .library(name: "DriftboxDesktop", targets: ["DriftboxDesktop"]),
  ],
  targets: [
    // Constrained: arithmetic only.
    .target(name: "DriftboxDSP"),
    .target(name: "DriftboxSeq"),
    .target(name: "DriftboxEngine", dependencies: ["DriftboxDSP", "DriftboxSeq"]),
    // The modular rack: modules, cables between any of them, one graph at sample rate.
    .target(name: "DriftboxRack", dependencies: ["DriftboxDSP"]),

    // Unconstrained: Foundation and the platform are allowed from here up.
    .target(name: "DriftboxDocument", dependencies: ["DriftboxSeq", "DriftboxEngine", "DriftboxRack"]),
    .target(name: "DriftboxHost", dependencies: ["DriftboxEngine", "DriftboxDocument", "DriftboxRack"]),
    // The host on Windows: WASAPI and WinMM behind the ports `DriftboxHost` declares. The C target is
    // only the system headers Swift's WinSDK module leaves out; every call is made from Swift.
    .systemLibrary(name: "CWASAPI"),
    .target(
      name: "DriftboxHostWindows",
      dependencies: ["DriftboxHost", .target(name: "CWASAPI", condition: .when(platforms: [.windows]))]),
    // The host on Android: AAudio and native MIDI behind the same ports, the same way. Its choice
    // of cores and its port names build everywhere, so that they are tested everywhere; the rest
    // compiles to nothing off Android.
    .systemLibrary(name: "CAAudio"),
    .systemLibrary(name: "CAMidi"),
    .target(
      name: "DriftboxHostAndroid",
      dependencies: [
        "DriftboxHost", .target(name: "CAAudio", condition: .when(platforms: [.android])),
        .target(name: "CAMidi", condition: .when(platforms: [.android])),
      ]),
    // The Android app's native library: what `android/`'s Java calls, and the tests it runs on a
    // phone. Built into libdriftbox.so by `scripts/android-app.sh`; nothing off Android.
    .target(
      name: "DriftboxAndroid",
      dependencies: [
        "DriftboxHostAndroid", "DriftboxHost", "DriftboxSeq", "DriftboxEngine", "DriftboxDocument",
        "DriftboxGPU", "DriftboxGPUGLES", "DriftboxScenes", "DriftboxText", "DriftboxTextAndroid",
        .target(name: "CAMidi", condition: .when(platforms: [.android])),
        .target(name: "CGLES", condition: .when(platforms: [.android])),
      ]),
    // What the scenes ask of a GPU, and the backends that answer it. The shaders are GLSL in
    // `shaders/`, made into every backend's language by `scripts/shaders.mjs` and checked in.
    .target(name: "DriftboxGPU"),
    // Metal on the Mac and iOS; nothing anywhere else.
    .target(name: "DriftboxGPUMetal", dependencies: ["DriftboxGPU"]),
    .target(
      name: "DriftboxGPUD3D11", dependencies: ["DriftboxGPU"],
      linkerSettings: [
        .linkedLibrary("d3d11", .when(platforms: [.windows])),
        .linkedLibrary("d3dcompiler", .when(platforms: [.windows])),
      ]),
    // What a window gives the app — input, menus, a loop to draw in, file panels — in terms that are
    // the same on every platform, and the Windows shell that answers it with Win32.
    .target(name: "DriftboxShell"),
    .target(name: "DriftboxWin32", dependencies: ["DriftboxShell"]),
    // Type: a line set in a font and a glyph's coverage, which is all that is asked of a platform,
    // and DirectWrite answering it on Windows. DirectWrite's headers are C++ only, so the C target
    // declares the part of it that is called; every call is made from Swift.
    .target(name: "DriftboxText"),
    .systemLibrary(name: "CDirectWrite"),
    .target(
      name: "DriftboxTextWindows",
      dependencies: ["DriftboxText", .target(name: "CDirectWrite", condition: .when(platforms: [.windows]))]),
    // And Android's own text stack answering it on Android, through the app's Java; nothing off it.
    .target(name: "DriftboxTextAndroid", dependencies: ["DriftboxText"]),
    // A 2D canvas on the GPU layer, the same on every platform but for the type it is given.
    .target(name: "DriftboxCanvas", dependencies: ["DriftboxGPU", "DriftboxText"]),
    // The GPU layer on OpenGL ES 3.0: Android's, and Linux's, where Mesa draws it in software for CI.
    // OpenGL ES is libGLESv3 on Android and libGLESv2 on Linux, which carries 3.0 as well.
    .systemLibrary(name: "CGLES"),
    .target(
      name: "DriftboxGPUGLES",
      dependencies: [
        "DriftboxGPU", .target(name: "CGLES", condition: .when(platforms: [.android, .linux])),
      ],
      linkerSettings: [
        .linkedLibrary("GLESv3", .when(platforms: [.android])),
        .linkedLibrary("GLESv2", .when(platforms: [.linux])),
      ]),
    // The visuals: scenes driven by the engine's events, moving from Metal onto the GPU layer. On a
    // platform without Metal, the ones that have moved.
    .target(
      name: "DriftboxScenes",
      dependencies: ["DriftboxDSP", "DriftboxEngine", "DriftboxGPU", "DriftboxText", "DriftboxCanvas"]),

    // What an app holds, on every platform: the song, the transport, editing and undo, the MIDI
    // clock both ways, what is remembered — everything but the views, on the ports. With the
    // catalogue of songs every platform's app ships.
    .target(
      name: "DriftboxSession",
      dependencies: ["DriftboxDocument", "DriftboxEngine", "DriftboxHost", "DriftboxScenes", "DriftboxSeq"],
      resources: [.copy("Resources/Songs"), .copy("Resources/catalogue.json")]),

    // Driftbox on a desktop: a window with menus, the song's scene, the pad. The same on every
    // platform with a `ShellWindow`; each platform's app only chooses its parts.
    .target(
      name: "DriftboxDesktop",
      dependencies: [
        "DriftboxDocument", "DriftboxGPU", "DriftboxHost", "DriftboxScenes", "DriftboxSession",
        "DriftboxShell",
        "DriftboxText",
      ]),
    // Driftbox for Windows: Windows' parts, chosen, and handed to `Desktop`.
    .executableTarget(
      name: "DriftboxWindows",
      dependencies: [
        "DriftboxDesktop", "DriftboxHost", "DriftboxSession",
        .target(name: "DriftboxGPUD3D11", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxHostWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxWin32", condition: .when(platforms: [.windows])),
      ]),

    // A song document in, a WAV file out: something to listen to.
    .executableTarget(name: "driftbox-render", dependencies: ["DriftboxEngine", "DriftboxDocument"]),
    // The Mac app, all of it but the entry point. A library rather than part of the executable
    // because an executable target is the one kind a test target may not depend on, and the
    // transport, the timeline, the clock out and the document rules all live here.
    .target(
      name: "DriftboxApp",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxSeq", "DriftboxScenes", "DriftboxRack",
        "DriftboxSession",
      ],
      resources: [
        .copy("Resources/AppIcon.icns"),
        .copy("Resources/Patches"), .copy("Resources/patches.json"), .copy("Resources/modules.json"),
      ]),
    // `@main` and nothing else, so that everything it starts can be reached from a test.
    .executableTarget(name: "Driftbox", dependencies: ["DriftboxApp"]),
    // A song document in, the speakers out: the engine as an Audio Unit in an AVAudioEngine on the
    // Mac, a WASAPI stream behind `AudioRouting` on Windows, and an AAudio one on Android.
    .executableTarget(
      name: "driftbox-play",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxGPU", "DriftboxScenes", "DriftboxText",
        .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxHostWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxHostAndroid", condition: .when(platforms: [.android])),
        .target(name: "DriftboxGPUD3D11", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxGPUMetal", condition: .when(platforms: [.macOS])),
        .target(name: "DriftboxShell", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxWin32", condition: .when(platforms: [.windows])),
      ]),

    // Finds and reads `conformance/fixtures` for every test target.
    .target(name: "ConformanceSupport", dependencies: ["DriftboxDocument"], path: "Tests/ConformanceSupport"),

    .testTarget(name: "DriftboxDSPTests", dependencies: ["DriftboxDSP", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxSeqTests",
      dependencies: ["DriftboxSeq", "DriftboxDSP", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxEngineTests",
      dependencies: ["DriftboxEngine", "DriftboxSeq", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxRackTests",
      dependencies: ["DriftboxRack", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxHostWindowsTests", dependencies: ["DriftboxHostWindows", "DriftboxHost", "DriftboxSeq"]),
    .testTarget(name: "DriftboxHostAndroidTests", dependencies: ["DriftboxHostAndroid"]),
    .testTarget(
      name: "DriftboxGPUTests",
      dependencies: [
        "DriftboxGPU", "DriftboxGPUD3D11", "DriftboxGPUMetal", "DriftboxGPUGLES", "DriftboxWin32",
      ]),
    .testTarget(
      name: "DriftboxShellTests",
      dependencies: [
        "DriftboxShell", .target(name: "DriftboxWin32", condition: .when(platforms: [.windows])),
      ]),
    .testTarget(
      name: "DriftboxSessionTests",
      dependencies: [
        "DriftboxSession", "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxSeq",
        "ConformanceSupport",
      ]),
    .testTarget(
      name: "DriftboxDesktopTests",
      dependencies: [
        "DriftboxDesktop", "DriftboxSession", "DriftboxShell", "DriftboxGPU", "DriftboxHost", "DriftboxSeq",
        "DriftboxText", "DriftboxDocument", "DriftboxGPUD3D11", "DriftboxGPUMetal", "DriftboxGPUGLES",
      ]),
    .testTarget(
      name: "DriftboxTextTests",
      dependencies: [
        "DriftboxText", .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
      ]),
    .testTarget(
      name: "DriftboxCanvasTests",
      dependencies: [
        "DriftboxCanvas", "DriftboxGPU", "DriftboxText", "DriftboxGPUD3D11", "DriftboxGPUMetal",
        "DriftboxGPUGLES", .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
      ]),
    .testTarget(
      name: "DriftboxScenesTests",
      dependencies: [
        "DriftboxScenes", "DriftboxEngine", "DriftboxGPU", "DriftboxGPUD3D11", "DriftboxGPUMetal",
        "DriftboxText",
        .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
      ]),
    .testTarget(
      name: "DriftboxHostTests",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxRack", "ConformanceSupport",
      ]),
    .testTarget(
      name: "DriftboxDocumentTests",
      dependencies: ["DriftboxDocument", "DriftboxSeq", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxAppTests",
      dependencies: [
        "DriftboxApp", "DriftboxHost", "DriftboxSeq", "DriftboxDocument", "DriftboxRack",
        "ConformanceSupport",
      ]
    ),
  ]
)
