#if canImport(Metal)
  import DriftboxEngine
  import DriftboxScenes
  import Metal
  import Testing

  /// Nobody can look at a scene from here, but a scene can be drawn into a texture and read back:
  /// dark when nothing is happening, brighter on a kick, and different again on a note.
  struct SceneTests {
    static func readBack(_ texture: MTLTexture) -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
      bytes.withUnsafeMutableBytes { raw in
        texture.getBytes(
          raw.baseAddress!, bytesPerRow: texture.width * 4,
          from: MTLRegionMake2D(0, 0, texture.width, texture.height),
          mipmapLevel: 0)
      }
      return bytes
    }

    static func brightness(_ bytes: [UInt8]) -> Double {
      var total = 0
      for index in stride(from: 0, to: bytes.count, by: 4) {
        total += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
      }
      return Double(total) / Double(bytes.count / 4 * 3 * 255)
    }

    @Test func theFallbackSceneReactsToWhatIsPlayed() throws {
      guard let device = MTLCreateSystemDefaultDevice() else { return }
      let renderer = try SceneRenderer(device: device, sceneId: "no such scene", now: 0)
      #expect(renderer.sceneType.id == "pulse")

      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 160, height: 90, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .shared
      let texture = try #require(device.makeTexture(descriptor: descriptor))

      func frame(at now: Double, events: [EngineEvent] = [], peak: Float = 0) -> [UInt8] {
        renderer.draw(into: texture, now: now, peakLeft: peak, peakRight: peak, events: events)
        renderer.queue.makeCommandBuffer().map { buffer in
          buffer.commit()
          buffer.waitUntilCompleted()
        }
        return Self.readBack(texture)
      }

      let quiet = frame(at: 1)
      let kick = allVoices.firstIndex { $0.id == "909.bd" }!
      let struck = frame(
        at: 1.05, events: [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)])
      let later = frame(at: 3)
      let note = frame(
        at: 3.05, events: [EngineEvent(kind: .note, frame: 0, voice: 0, level: 0.6, frequency: 110, flag: 0)])

      #expect(Self.brightness(quiet) < 0.08, "quiet is dark: \(Self.brightness(quiet))")
      #expect(Self.brightness(struck) > Self.brightness(quiet) + 0.005, "a kick lights it")
      #expect(Self.brightness(later) < Self.brightness(struck), "and it fades")
      #expect(note != later, "a note draws something")
    }
  }
#endif
