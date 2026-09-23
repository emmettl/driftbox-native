import DriftboxGPU
import DriftboxScenes
import Foundation
import Testing

#if canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#endif

/// The material studies on the GPU layer, on every backend this platform has: each one draws, is
/// not black, and moves when the music does. What each draws is held to the Metal scene's on the
/// Mac, below; here it is only held to drawing at all.
struct SurfaceSceneTests {
  static var surfaces: [any GPUScene.Type] { GPUScenes.all.filter { $0 is GPUSurfaceScene.Type } }

  /// A few seconds of playing: running, on the beat, the bands up, a finger down for a while.
  static func playing(at time: Double) -> SceneInput {
    let swell = Float(0.5 + 0.4 * sin(time * 3))
    return SceneInput(
      time: time, touch: time > 1 ? SIMD2(0.3, 0.6) : nil, running: true, bpm: 124,
      scoreBeat: time * 124 / 60, levels: (swell, swell * 0.8, swell * 0.6),
      wideLevels: (swell, swell * 0.5))
  }

  @Test func everySurfaceDrawsAndMoves() throws {
    #expect(Self.surfaces.count == 9)
    for device in try PulseSceneTests.devices() {
      for type in Self.surfaces {
        let scene = try type.init(device: device)
        let target = try device.makeTarget(width: 160, height: 90)
        var frames: [[UInt8]] = []
        for time in stride(from: 0.0, through: 3, by: 1.0 / 30) {
          scene.draw(Self.playing(at: time), into: target, on: device)
          if [1.0, 3.0].contains(where: { abs($0 - time) < 0.001 }) {
            frames.append(try device.readPixels(target))
          }
        }
        let brightness = PulseSceneTests.brightness(frames[1])
        #expect(brightness > 0.01, "\(type.id) is not black: \(brightness)")
        #expect(frames[0] != frames[1], "\(type.id) moves")
      }
    }
  }

  @Test func songsFindTheirScenes() {
    // By identity: Swift 6.4 on Windows crashes lowering `is X.Type` in an #expect.
    func found(_ id: String?) -> ObjectIdentifier { ObjectIdentifier(GPUScenes.type(for: id)) }
    #expect(found("frost") == ObjectIdentifier(FrostScene.self))
    #expect(found("nightbus") == ObjectIdentifier(NightBusScene.self))
    #expect(found("not-yet") == ObjectIdentifier(PulseScene.self))
    #expect(found(nil) == ObjectIdentifier(PulseScene.self))
    let ids = GPUScenes.all.map { $0.id }
    #expect(Set(ids).count == ids.count, "ids are unique")
  }

  /// The cards' buffer is made once, to fit; a window of any shape lays out as many as that.
  @Test func cardsFitTheirBuffers() throws {
    for device in try PulseSceneTests.devices() {
      let scenes: [GPUSurfaceScene] = [try FrostScene(device: device), try HothouseScene(device: device)]
      for scene in scenes {
        for aspect: Float in [0.5, 1, 16.0 / 9, 3] {
          #expect(scene.cards(aspect: aspect).count == type(of: scene).cardCount)
        }
      }
    }
  }
}

#if canImport(Metal)
  /// On the Mac both can be drawn, so each surface on the GPU layer is held to the Metal one
  /// frame by frame through a few seconds of playing: the same shader, back from MSL to GLSL and
  /// out again, fed the same clocks. The noise the scenes make from `sin` of large numbers is not
  /// bit-for-bit the same between the two compilations, so a few pixels may differ; the frame as a
  /// whole may not.
  struct SurfacesAgainstMetalTests {
    @Test func theLayersSurfacesDrawWhatTheMetalOnesDraw() throws {
      guard let metal = MTLCreateSystemDefaultDevice() else { return }
      let device = try MetalDevice(device: metal)
      for type in SurfaceSceneTests.surfaces {
        #expect(Scenes.type(for: type.id).id == type.id, "\(type.id) is a Metal scene too")
        #expect(Scenes.type(for: type.id).name == type.name)
        #expect(Scenes.type(for: type.id).accent == type.accent)

        let renderer = try SceneRenderer(device: metal, sceneId: type.id, now: 0)
        let description = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .bgra8Unorm, width: 160, height: 90, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        let texture = try #require(metal.makeTexture(descriptor: description))
        let scene = try type.init(device: device)
        let target = try device.makeTarget(width: 160, height: 90)

        for time in stride(from: 0.0, through: 3, by: 1.0 / 30) {
          let input = SurfaceSceneTests.playing(at: time)
          renderer.draw(input, into: texture)
          renderer.queue.makeCommandBuffer().map { buffer in
            buffer.commit()
            buffer.waitUntilCompleted()
          }
          scene.draw(input, into: target, on: device)
          guard Int((time * 30).rounded()) % 15 == 0 else { continue }
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
