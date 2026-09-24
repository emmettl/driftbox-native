import DriftboxEngine
import DriftboxGPU
import DriftboxScenes
import DriftboxText
import Foundation
import Testing

#if os(Windows)
  import DriftboxTextWindows
#endif

#if canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#endif

/// Every scene that has moved onto the GPU layer, on every backend this platform has: each one
/// draws, is not black, and moves, through the same six seconds the Metal scenes' own test plays
/// them. What each draws is held to its Metal scene on the Mac, below; here it is only held to
/// drawing at all. With `DRIFTBOX_SCENE_SHOTS` set to a directory, each is also written there as
/// BMPs at three moments, which is how anyone looks at one without a window.
struct GPUSceneTests {
  /// The platform's typesetter where it has one, for Graphic Lab's type; none, and Graphic Lab
  /// prints its sheets without it, elsewhere.
  static func typesetter() throws -> any Typesetter {
    #if os(Windows)
      return try DirectWriteTypesetter()
    #else
      return NoTypesetter()
    #endif
  }

  /// Everything but Pulse, which has a test of its own, since a frame of it with nothing playing
  /// is meant to be dark.
  static var moved: [any GPUScene.Type] { GPUScenes.all.filter { $0.id != PulseScene.id } }

  /// Sixty frames a second: a kick every beat at 126, hats between, the bands with them, and a
  /// finger drawing a circle through the middle two seconds. Every scene reacts to a touch, and
  /// one of them — Longhand — is a blank page until something is drawn on it.
  static func input(at time: Double) -> SceneInput {
    let beat = time * 126 / 60
    let onBeat = beat - beat.rounded(.down) < 0.1
    let bands: (bass: Float, mid: Float, high: Float) = (onBeat ? 0.8 : 0.2, onBeat ? 0.5 : 0.15, 0.3)
    let struck = beat - beat.rounded(.down) < 1.0 / 60 * 126 / 60
    let kick = allVoices.firstIndex { $0.id == "909.bd" }!
    let touch: SIMD2<Float>? =
      (2..<4).contains(time)
      ? SIMD2(0.5 + 0.3 * Float(cos(time * 3)), 0.5 + 0.3 * Float(sin(time * 3))) : nil
    return SceneInput(
      time: time, peakLeft: onBeat ? 0.8 : 0.2, peakRight: onBeat ? 0.8 : 0.2,
      events: struck ? [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)] : [],
      touch: touch, running: true, bpm: 126, scoreBeat: beat, levels: bands,
      wideLevels: (bands.bass, bands.high),
      bands: (0..<16).map { onBeat && $0 < 4 ? 0.7 : Float($0) / 40 })
  }

  /// The six seconds, as frames, stopping at the end of each two to hand one over.
  static func play(
    _ scene: any GPUScene, into target: any GPUTarget, on device: any GPUDevice,
    moment: (Int, Double) throws -> Void
  ) rethrows {
    var time = 0.0
    for index in 0..<3 {
      while time < Double(index + 1) * 2 {
        scene.draw(input(at: time), into: target, on: device)
        time += 1.0 / 60
      }
      try moment(index, time)
    }
  }

  @Test func everySceneDrawsAndMoves() throws {
    let shots = ProcessInfo.processInfo.environment["DRIFTBOX_SCENE_SHOTS"]
    let size = shots == nil ? SIMD2(160, 90) : SIMD2(640, 360)
    for device in try PulseSceneTests.devices() {
      for type in Self.moved {
        let scene = try type.init(device: device, typesetter: GPUSceneTests.typesetter())
        let target = try device.makeTarget(width: size.x, height: size.y)
        var frames: [[UInt8]] = []
        try Self.play(scene, into: target, on: device) { moment, _ in
          let bytes = try device.readPixels(target)
          frames.append(bytes)
          if let shots {
            try Self.bitmap(bytes, width: size.x, height: size.y)
              .write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(type.id)-\(moment).bmp"))
          }
        }
        let brightness = PulseSceneTests.brightness(frames[0])
        #expect(brightness > 0.01, "\(type.id) draws something: \(brightness)")
        #expect(frames[0] != frames[1] || frames[1] != frames[2], "\(type.id) moves")
      }
    }
  }

  @Test func songsFindTheirScenes() {
    // By identity: Swift 6.4 on Windows crashes lowering `is X.Type` in an #expect.
    func found(_ id: String?) -> ObjectIdentifier { ObjectIdentifier(GPUScenes.type(for: id)) }
    #expect(found("frost") == ObjectIdentifier(FrostScene.self))
    #expect(found("nightbus") == ObjectIdentifier(NightBusScene.self))
    #expect(found("wireframe") == ObjectIdentifier(WireframeScene.self))
    #expect(found("not-yet") == ObjectIdentifier(PulseScene.self))
    #expect(found(nil) == ObjectIdentifier(PulseScene.self))
    let ids = GPUScenes.all.map { $0.id }
    #expect(Set(ids).count == ids.count, "ids are unique")
  }

  /// The cards' buffer is made once, to fit; a window of any shape lays out as many as that.
  @Test func cardsFitTheirBuffers() throws {
    for device in try PulseSceneTests.devices() {
      let scenes: [GPUSurfaceScene] = [
        try FrostScene(device: device, typesetter: NoTypesetter()),
        try HothouseScene(device: device, typesetter: NoTypesetter()),
      ]
      for scene in scenes {
        for aspect: Float in [0.5, 1, 16.0 / 9, 3] {
          #expect(scene.cards(aspect: aspect).count == type(of: scene).cardCount)
        }
      }
    }
  }

  /// BGRA pixels, rows from the top, as a 32-bit BMP: the one image format that needs nothing
  /// but its own header.
  static func bitmap(_ pixels: [UInt8], width: Int, height: Int) -> Data {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("BM".utf8))
    put(UInt32(54 + pixels.count))
    put(UInt32(0))
    put(UInt32(54))
    put(UInt32(40))
    put(Int32(width))
    put(Int32(-height))  // negative: rows from the top, as the pixels are
    put(UInt16(1))
    put(UInt16(32))
    for _ in 0..<6 { put(UInt32(0)) }
    data.append(contentsOf: pixels)
    return data
  }
}

#if canImport(Metal)
  /// On the Mac both can be drawn, so each scene on the GPU layer is held to the Metal one frame
  /// by frame through the same six seconds: the same shaders, back from MSL to GLSL and out again,
  /// fed the same input. The noise some scenes make from `sin` of large numbers is not bit for bit
  /// the same between the two compilations, so a few pixels may differ; the frame as a whole may not.
  struct ScenesAgainstMetalTests {
    @Test func theLayersScenesDrawWhatTheMetalOnesDraw() throws {
      guard let metal = MTLCreateSystemDefaultDevice() else { return }
      let device = try MetalDevice(device: metal)
      // Not Graphic Lab yet: its type is Core Text's in Metal, and the Mac has no typesetter on the
      // layer until there is a Core Text one, so the two would differ by every letter.
      for type in GPUSceneTests.moved where type.id != GraphicLabScene.id {
        #expect(Scenes.type(for: type.id).id == type.id, "\(type.id) is a Metal scene too")
        #expect(Scenes.type(for: type.id).name == type.name)
        #expect(Scenes.type(for: type.id).accent == type.accent)

        let renderer = try SceneRenderer(device: metal, sceneId: type.id, now: 0)
        let description = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .bgra8Unorm, width: 160, height: 90, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        let texture = try #require(metal.makeTexture(descriptor: description))
        let scene = try type.init(device: device, typesetter: GPUSceneTests.typesetter())
        let target = try device.makeTarget(width: 160, height: 90)

        var time = 0.0
        while time < 6 {
          let input = GPUSceneTests.input(at: time)
          renderer.draw(input, into: texture)
          renderer.queue.makeCommandBuffer().map { buffer in
            buffer.commit()
            buffer.waitUntilCompleted()
          }
          scene.draw(input, into: target, on: device)
          time += 1.0 / 60
          guard Int((time * 60).rounded()) % 30 == 0 else { continue }
          var theirs = [UInt8](repeating: 0, count: 160 * 90 * 4)
          theirs.withUnsafeMutableBytes { raw in
            texture.getBytes(
              raw.baseAddress!, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
          }
          let mine = try device.readPixels(target)
          let differences = zip(mine, theirs).map { abs(Int($0) - Int($1)) }
          let far = differences.filter { $0 > 2 }.count
          let mean = Double(differences.reduce(0, +)) / Double(differences.count)
          #expect(
            Double(far) / Double(differences.count) < 0.01 && mean < 0.5,
            "\(type.id) at \(time)s: \(far) channels differ by more than 2, by \(mean) on average")
        }
      }
    }
  }
#endif
