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
    .library(name: "DriftboxHostMac", targets: ["DriftboxHostMac"]),
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
    .library(name: "DriftboxRackSession", targets: ["DriftboxRackSession"]),
    .library(name: "DriftboxInterface", targets: ["DriftboxInterface"]),
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
    // The host on the Mac: Core Audio, Core MIDI and Audio Units behind the ports `DriftboxHost`
    // declares, and the engine and the rack as Audio Units of their own. Nothing off Apple's
    // platforms.
    .target(
      name: "DriftboxHostMac",
      dependencies: ["DriftboxHost", "DriftboxEngine", "DriftboxRack", "DriftboxSeq", "DriftboxDocument"]),
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

    // The rack as an app holds it, on every platform: the patch and its edits and undo, the keys and
    // the controllers, the samples, the song it carries, the transport; with the catalogue of patches.
    // Where it sounds, which plug-ins it can host and which files it can read are the platform's ports.
    .target(
      name: "DriftboxRackSession",
      dependencies: ["DriftboxDocument", "DriftboxEngine", "DriftboxHost", "DriftboxRack", "DriftboxSeq"],
      resources: [
        .copy("Resources/Patches"), .copy("Resources/patches.json"), .copy("Resources/modules.json"),
      ]),

    // The controls, drawn on a canvas over the scene: the transport and the step grid, the same on
    // every platform, reading the session and editing it.
    .target(
      name: "DriftboxInterface",
      dependencies: [
        "DriftboxCanvas", "DriftboxEngine", "DriftboxRack", "DriftboxRackSession",
        "DriftboxSeq", "DriftboxSession", "DriftboxShell", "DriftboxText",
      ]),

    // Driftbox on a desktop: a window with menus, the song's scene, the pad. The same on every
    // platform with a `ShellWindow`; each platform's app only chooses its parts.
    .target(
      name: "DriftboxDesktop",
      dependencies: [
        "DriftboxCanvas", "DriftboxDocument", "DriftboxGPU", "DriftboxHost", "DriftboxInterface",
        "DriftboxRackSession", "DriftboxScenes", "DriftboxSession", "DriftboxShell", "DriftboxText",
      ]),
    // Driftbox on a touch screen: the scene, the controls over it, the pad, fingers. The same on every
    // platform with one; Android's app hands it its parts, and iOS's will.
    .target(
      name: "DriftboxTouch",
      dependencies: [
        "DriftboxCanvas", "DriftboxGPU", "DriftboxHost", "DriftboxInterface", "DriftboxScenes",
        "DriftboxSession", "DriftboxShell", "DriftboxText",
      ]),
    // Driftbox for Windows: Windows' parts, chosen, and handed to `Desktop`.
    .executableTarget(
      name: "DriftboxWindows",
      dependencies: [
        "DriftboxDesktop", "DriftboxHost", "DriftboxRackSession", "DriftboxSession",
        .target(name: "DriftboxGPUD3D11", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxHostWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxWin32", condition: .when(platforms: [.windows])),
      ],
      // Its icon, and whatever else Windows keeps in a program: windows/Driftbox.res, which
      // scripts/windows-icon.mjs makes. The linker takes a compiled resource file as it takes an object.
      linkerSettings: [
        .unsafeFlags([Context.packageDirectory + "/windows/Driftbox.res"], .when(platforms: [.windows]))
      ]),

    // A song document in, a WAV file out: something to listen to.
    .executableTarget(name: "driftbox-render", dependencies: ["DriftboxEngine", "DriftboxDocument"]),
    // The Mac app, all of it but the entry point. A library rather than part of the executable
    // because an executable target is the one kind a test target may not depend on, and the
    // transport, the timeline, the clock out and the document rules all live here.
    .target(
      name: "DriftboxApp",
      dependencies: [
        "DriftboxHost", "DriftboxHostMac", "DriftboxEngine", "DriftboxDocument", "DriftboxSeq",
        "DriftboxScenes", "DriftboxRack", "DriftboxSession", "DriftboxRackSession",
      ],
      // The rack's patches and module cards are `DriftboxRackSession`'s, as every platform ships them.
      resources: [.copy("Resources/AppIcon.icns")]),
    // The rack and the groovebox as an AUv3 app extension, for other apps to load. Its entry
    // point is Foundation's `NSExtensionMain`, not a `main` of its own; `scripts/bundle-app.sh`
    // puts it in the app.
    .target(
      name: "DriftboxExtensions",
      dependencies: [
        "DriftboxApp", "DriftboxHostMac", "DriftboxHost", "DriftboxRackSession", "DriftboxSession",
        "DriftboxDocument", "DriftboxSeq",
      ]),
    .executableTarget(
      name: "DriftboxAudioUnits", dependencies: ["DriftboxExtensions", "DriftboxHostMac"],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"], .when(platforms: [.macOS]))
      ]),
    // `@main` and nothing else, so that everything it starts can be reached from a test.
    .executableTarget(name: "Driftbox", dependencies: ["DriftboxApp"]),
    // A song document in, the speakers out: the engine as an Audio Unit in an AVAudioEngine on the
    // Mac, a WASAPI stream behind `AudioRouting` on Windows, and an AAudio one on Android.
    .executableTarget(
      name: "driftbox-play",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxGPU", "DriftboxScenes", "DriftboxText",
        .target(name: "DriftboxHostMac", condition: .when(platforms: [.macOS])),
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
        "DriftboxDesktop", "DriftboxInterface", "DriftboxRackSession", "DriftboxSession", "DriftboxShell",
        "DriftboxGPU",
        "DriftboxHost", "DriftboxSeq",
        "DriftboxText", "DriftboxDocument", "DriftboxGPUD3D11", "DriftboxGPUMetal", "DriftboxGPUGLES",
      ]),
    .testTarget(
      name: "DriftboxRackSessionTests",
      dependencies: [
        "DriftboxRackSession", "ConformanceSupport", "DriftboxDocument", "DriftboxEngine", "DriftboxHost",
        "DriftboxRack", "DriftboxSeq",
      ]),
    .testTarget(
      name: "DriftboxInterfaceTests",
      dependencies: [
        "DriftboxInterface", "DriftboxRack", "DriftboxRackSession", "DriftboxCanvas", "DriftboxEngine",
        "DriftboxGPU", "DriftboxHost", "DriftboxSeq",
        "DriftboxSession", "DriftboxShell", "DriftboxText", "DriftboxGPUD3D11", "DriftboxGPUMetal",
        "DriftboxGPUGLES",
        .target(name: "DriftboxTextWindows", condition: .when(platforms: [.windows])),
      ]),
    .testTarget(
      name: "DriftboxTouchTests",
      dependencies: [
        "DriftboxGPU", "DriftboxHost", "DriftboxSession", "DriftboxShell", "DriftboxText", "DriftboxTouch",
        .target(name: "DriftboxGPUD3D11", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxGPUMetal", condition: .when(platforms: [.macOS, .iOS])),
        .target(name: "DriftboxGPUGLES", condition: .when(platforms: [.linux])),
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
      name: "DriftboxExtensionsTests",
      dependencies: ["DriftboxExtensions", "DriftboxHostMac", "DriftboxRackSession", "DriftboxDocument"]),
    .testTarget(
      name: "DriftboxHostMacTests",
      dependencies: [
        "DriftboxHostMac", "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxRack",
        "DriftboxSeq", "ConformanceSupport",
      ]),
    .testTarget(
      name: "DriftboxDocumentTests",
      dependencies: ["DriftboxDocument", "DriftboxSeq", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxAppTests",
      dependencies: [
        "DriftboxApp", "DriftboxHost", "DriftboxSeq", "DriftboxDocument", "DriftboxRack",
        "DriftboxRackSession", "DriftboxSession", "ConformanceSupport",
      ]
    ),
  ],
  cxxLanguageStandard: .cxx17
)

// VST 3 plug-ins, on Steinberg's SDK (MIT), vendored at 3.8.1 build 84 as much as is used: `VST3SDK`
// the SDK, a host's part of it; `CVST3` Driftbox's bridge to it in C, for Swift; and
// `DriftboxVST3Fixture`, a plug-in built from it for the tests to load as a real one is loaded, a
// library of its own. Driftbox hosts plug-ins on Windows alone for now, so all of it compiles there
// alone: the SDK's sources sit in an `sdk` folder the build leaves out, and each is compiled through
// a wrapper in `windows` that includes it only there. Apart from the rest, which the manifest's type
// checker cannot take in one go.
package.products.append(
  .library(name: "DriftboxVST3Fixture", type: .dynamic, targets: ["DriftboxVST3Fixture"]))
package.targets += [
  .target(
    name: "VST3SDK",
    exclude: ["LICENSE-VST3SDK.txt", "sdk"],
    // Where the SDK's own sources look for the headers they expect beside them.
    cxxSettings: [
      "base/source", "pluginterfaces/base", "public.sdk/source/common", "public.sdk/source/vst",
      "public.sdk/source/vst/hosting", "public.sdk/source/vst/utility",
    ].map { .headerSearchPath("include/\($0)") } + [.define("RELEASE", to: "1")],
    // On Windows its base classes use a few of user32's and ole32's calls, and the C runtime's old
    // names for its wide-string comparisons.
    linkerSettings: ["user32", "ole32", "oldnames"].map { .linkedLibrary($0, .when(platforms: [.windows])) }),
  .target(name: "CVST3", dependencies: ["VST3SDK"], cxxSettings: [.define("RELEASE", to: "1")]),
  .target(
    name: "DriftboxVST3Fixture", dependencies: ["VST3SDK"], path: "Tests/DriftboxVST3Fixture",
    exclude: ["LICENSE-VST3SDK.txt", "sdk"],
    // It compiles the SDK's edit controller itself, for the effect whose controller is its own class;
    // the single-component synth would otherwise compile a second copy into itself.
    cxxSettings: [
      .headerSearchPath("sdk"), .define("RELEASE", to: "1"), .define("PROJECT_INCLUDES_VSTEDITCONTROLLER"),
    ],
    // A library product is linked by the Swift driver, which registers it with the Swift runtime even
    // with no Swift in it: the test plug-in loads beside the tests, where the runtime is.
    linkerSettings: [.linkedLibrary("swiftCore", .when(platforms: [.windows]))]),
  .testTarget(
    name: "DriftboxVST3Tests", dependencies: [.target(name: "CVST3", condition: .when(platforms: [.windows]))]
  ),
]
