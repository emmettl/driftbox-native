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
    .target(name: "DriftboxDocument", dependencies: ["DriftboxSeq", "DriftboxEngine"]),
    .target(name: "DriftboxHost", dependencies: ["DriftboxEngine", "DriftboxDocument"]),
    // The visuals: Metal scenes driven by the engine's events. Empty on a platform without Metal.
    .target(name: "DriftboxScenes", dependencies: ["DriftboxDSP", "DriftboxEngine"]),

    // A song document in, a WAV file out: something to listen to.
    .executableTarget(name: "driftbox-render", dependencies: ["DriftboxEngine", "DriftboxDocument"]),
    // The Mac app, all of it but the entry point. A library rather than part of the executable
    // because an executable target is the one kind a test target may not depend on, and the
    // transport, the timeline, the clock out and the document rules all live here.
    .target(
      name: "DriftboxApp",
      dependencies: ["DriftboxHost", "DriftboxEngine", "DriftboxDocument", "DriftboxSeq", "DriftboxScenes"],
      resources: [.copy("Resources/Songs"), .copy("Resources/catalogue.json")]),
    // `@main` and nothing else, so that everything it starts can be reached from a test.
    .executableTarget(name: "Driftbox", dependencies: ["DriftboxApp"]),
    // A song document in, the speakers out: the engine as an Audio Unit in an AVAudioEngine.
    .executableTarget(
      name: "driftbox-play", dependencies: ["DriftboxHost", "DriftboxEngine", "DriftboxDocument"]),

    // Finds and reads `conformance/fixtures` for every test target.
    .target(name: "ConformanceSupport", dependencies: ["DriftboxDocument"], path: "Tests/ConformanceSupport"),

    .testTarget(name: "DriftboxDSPTests", dependencies: ["DriftboxDSP", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxSeqTests",
      dependencies: ["DriftboxSeq", "DriftboxDSP", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxEngineTests",
      dependencies: ["DriftboxEngine", "DriftboxSeq", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(name: "DriftboxRackTests", dependencies: ["DriftboxRack", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(name: "DriftboxScenesTests", dependencies: ["DriftboxScenes", "DriftboxEngine"]),
    .testTarget(
      name: "DriftboxHostTests",
      dependencies: ["DriftboxHost", "DriftboxEngine", "DriftboxDocument", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxDocumentTests",
      dependencies: ["DriftboxDocument", "DriftboxSeq", "ConformanceSupport"]),
    .testTarget(
      name: "DriftboxAppTests",
      dependencies: ["DriftboxApp", "DriftboxHost", "DriftboxSeq", "DriftboxDocument", "ConformanceSupport"]
    ),
  ]
)
