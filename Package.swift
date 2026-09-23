// swift-tools-version: 6.4
import PackageDescription

// DriftboxDSP, DriftboxSeq, DriftboxEngine and DriftboxRack are held to a rule the compiler can check: no
// Foundation, no existentials, no reflection, nothing that needs a runtime or a platform.
// `scripts/check-constrained.sh` compiles them as Embedded Swift to prove it. It is a lint here,
// not a product, though it is also what keeps a WebAssembly build of the same sources possible.

let package = Package(
  name: "DriftboxKit",
  platforms: [.macOS(.v15), .iOS(.v18)],
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
    .library(name: "DriftboxScenes", targets: ["DriftboxScenes"]),
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
    // What the scenes ask of a GPU, and the backends that answer it. The shaders are GLSL in
    // `shaders/`, made into every backend's language by `scripts/shaders.mjs` and checked in.
    .target(name: "DriftboxGPU"),
    .target(
      name: "DriftboxGPUD3D11", dependencies: ["DriftboxGPU"],
      linkerSettings: [
        .linkedLibrary("d3d11", .when(platforms: [.windows])),
        .linkedLibrary("d3dcompiler", .when(platforms: [.windows])),
      ]),
    // The visuals: Metal scenes driven by the engine's events. Empty on a platform without Metal.
    .target(name: "DriftboxScenes", dependencies: ["DriftboxDSP", "DriftboxEngine"]),

    // A song document in, a WAV file out: something to listen to.
    .executableTarget(name: "driftbox-render", dependencies: ["DriftboxEngine", "DriftboxDocument"]),
    // The Mac app, all of it but the entry point. A library rather than part of the executable
    // because an executable target is the one kind a test target may not depend on, and the
    // transport, the timeline, the clock out and the document rules all live here.
    .target(
      name: "DriftboxApp",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxSeq", "DriftboxScenes", "DriftboxRack",
      ],
      resources: [
        .copy("Resources/Songs"), .copy("Resources/catalogue.json"), .copy("Resources/AppIcon.icns"),
        .copy("Resources/Patches"), .copy("Resources/patches.json"), .copy("Resources/modules.json"),
      ]),
    // `@main` and nothing else, so that everything it starts can be reached from a test.
    .executableTarget(name: "Driftbox", dependencies: ["DriftboxApp"]),
    // A song document in, the speakers out: the engine as an Audio Unit in an AVAudioEngine on the
    // Mac, a WASAPI stream behind `AudioRouting` on Windows, and an AAudio one on Android.
    .executableTarget(
      name: "driftbox-play",
      dependencies: [
        "DriftboxHost", "DriftboxEngine", "DriftboxDocument",
        .target(name: "DriftboxHostWindows", condition: .when(platforms: [.windows])),
        .target(name: "DriftboxHostAndroid", condition: .when(platforms: [.android])),
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
    .testTarget(name: "DriftboxGPUTests", dependencies: ["DriftboxGPU", "DriftboxGPUD3D11"]),
    .testTarget(name: "DriftboxScenesTests", dependencies: ["DriftboxScenes", "DriftboxEngine"]),
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
