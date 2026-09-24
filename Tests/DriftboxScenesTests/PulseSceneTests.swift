import DriftboxEngine
import DriftboxGPU
import DriftboxScenes
import DriftboxText
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#endif

/// Pulse on the GPU layer, held to what the Metal one's test holds it to: dark when nothing is
/// happening, brighter on a kick and fading after it, and different again on a note. On every backend
/// this platform has: Direct3D on WARP on Windows, Metal on the Mac.
struct PulseSceneTests {
  static func devices() throws -> [any GPUDevice] {
    #if os(Windows)
      return [try D3D11Device(driver: .software)]
    #elseif canImport(Metal)
      return MTLCreateSystemDefaultDevice() == nil ? [] : [try MetalDevice()]
    #else
      return []
    #endif
  }

  static func brightness(_ bytes: [UInt8]) -> Double {
    var total = 0
    for index in stride(from: 0, to: bytes.count, by: 4) {
      total += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
    }
    return Double(total) / Double(bytes.count / 4 * 3 * 255)
  }

  @Test func pulseReactsToWhatIsPlayed() throws {
    for device in try Self.devices() {
      let scene = try PulseScene(device: device, typesetter: NoTypesetter())
      let target = try device.makeTarget(width: 160, height: 90)
      func frame(at time: Double, events: [EngineEvent] = []) throws -> [UInt8] {
        scene.draw(SceneInput(time: time, events: events), into: target, on: device)
        return try device.readPixels(target)
      }

      let quiet = try frame(at: 1)
      let kick = allVoices.firstIndex { $0.id == "909.bd" }!
      let struck = try frame(
        at: 1.05, events: [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)])
      let later = try frame(at: 3)
      let note = try frame(
        at: 3.05, events: [EngineEvent(kind: .note, frame: 0, voice: 0, level: 0.6, frequency: 110, flag: 0)])

      #expect(Self.brightness(quiet) < 0.08, "quiet is dark: \(Self.brightness(quiet))")
      #expect(Self.brightness(struck) > Self.brightness(quiet) + 0.005, "a kick lights it")
      #expect(Self.brightness(later) < Self.brightness(struck), "and it fades")
      #expect(note != later, "a note draws something")
    }
  }

  @Test func pulseKeepsItsIdentity() {
    #expect(PulseScene.id == "pulse")
    #expect(PulseScene.accent == SIMD3(1.0, 0.62, 0.2))
  }
}

#if canImport(Metal)
  /// On the Mac both Pulses can be drawn, so the one on the GPU layer is held to the Metal one pixel
  /// by pixel, moment by moment: the same shader, from its GLSL, drawing the same frames.
  struct PulseAgainstMetalTests {
    @Test func theLayersPulseDrawsWhatTheMetalOneDraws() throws {
      guard let metal = MTLCreateSystemDefaultDevice() else { return }
      let renderer = try SceneRenderer(device: metal, sceneId: "pulse", now: 0)
      let description = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 160, height: 90, mipmapped: false)
      description.usage = [.renderTarget, .shaderRead]
      description.storageMode = .shared
      let texture = try #require(metal.makeTexture(descriptor: description))

      let device = try MetalDevice(device: metal)
      let scene = try PulseScene(device: device, typesetter: NoTypesetter())
      let target = try device.makeTarget(width: 160, height: 90)

      let kick = allVoices.firstIndex { $0.id == "909.bd" }!
      let snare = allVoices.firstIndex { $0.id == "909.sd" }!
      let moments: [(Double, [EngineEvent], Float)] = [
        (1, [], 0),
        (1.05, [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)], 0.8),
        (1.4, [EngineEvent(kind: .hit, frame: 0, voice: snare, level: 1, frequency: 0, flag: 0)], 0.5),
        (3.05, [EngineEvent(kind: .note, frame: 0, voice: 0, level: 0.6, frequency: 110, flag: 0)], 0.3),
        (7.5, [], 0.1),
      ]
      for (time, events, peak) in moments {
        let input = SceneInput(time: time, peakLeft: peak, peakRight: peak, events: events)
        renderer.draw(input, into: texture)
        renderer.queue.makeCommandBuffer().map { buffer in
          buffer.commit()
          buffer.waitUntilCompleted()
        }
        var theirs = [UInt8](repeating: 0, count: 160 * 90 * 4)
        theirs.withUnsafeMutableBytes { raw in
          texture.getBytes(
            raw.baseAddress!, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 90), mipmapLevel: 0)
        }
        scene.draw(input, into: target, on: device)
        let mine = try device.readPixels(target)
        let worst = zip(mine, theirs).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "at \(time)s the two differ by up to \(worst) in a channel")
      }
    }
  }
#endif
