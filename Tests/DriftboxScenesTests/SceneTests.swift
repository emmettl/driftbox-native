#if canImport(Metal)
  import DriftboxEngine
  import DriftboxScenes
  import Foundation
  import ImageIO
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
        renderer.draw(SceneInput(time: now, peakLeft: peak, peakRight: peak, events: events), into: texture)
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

    /// Every scene compiles, draws something that is not black, and moves. With
    /// `DRIFTBOX_SCENE_SHOTS` set to a directory, each is also written there as PNGs at three
    /// moments, which is the only way anyone gets to look at one from here.
    @Test(arguments: Scenes.all.map { $0.id })
    func everySceneDrawsAndMoves(id: String) throws {
      guard let device = MTLCreateSystemDefaultDevice() else { return }
      let renderer = try SceneRenderer(device: device, sceneId: id, now: 0)
      #expect(renderer.sceneType.id == id)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .shared
      let texture = try #require(device.makeTexture(descriptor: descriptor))
      let shots = ProcessInfo.processInfo.environment["DRIFTBOX_SCENE_SHOTS"]

      var frames: [[UInt8]] = []
      var time = 0.0
      for moment in 0..<3 {
        // Sixty frames a second up to each moment: a kick every beat at 126, hats between.
        while time < Double(moment + 1) * 2 {
          let beat = time * 126 / 60
          let onBeat = beat - beat.rounded(.down) < 0.1
          let bands: (bass: Float, mid: Float, high: Float) = (onBeat ? 0.8 : 0.2, onBeat ? 0.5 : 0.15, 0.3)
          let struck = beat - beat.rounded(.down) < 1.0 / 60 * 126 / 60
          let kick = allVoices.firstIndex { $0.id == "909.bd" }!
          renderer.draw(
            SceneInput(
              time: time, peakLeft: onBeat ? 0.8 : 0.2, peakRight: onBeat ? 0.8 : 0.2,
              events: struck
                ? [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)] : [],
              running: true, bpm: 126, scoreBeat: beat, levels: bands),
            into: texture)
          time += 1.0 / 60
        }
        renderer.queue.makeCommandBuffer().map { buffer in
          buffer.commit()
          buffer.waitUntilCompleted()
        }
        let bytes = Self.readBack(texture)
        frames.append(bytes)
        if let shots { try Self.writePNG(bytes, width: 640, height: 360, to: "\(shots)/\(id)-\(moment).png") }
      }
      #expect(Self.brightness(frames[0]) > 0.01, "\(id) draws something")
      #expect(frames[0] != frames[1] || frames[1] != frames[2], "\(id) moves")
    }

    static func writePNG(_ bgra: [UInt8], width: Int, height: Int, to path: String) throws {
      var rgba = bgra
      for index in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(index, index + 2) }
      let data = Data(rgba)
      guard let provider = CGDataProvider(data: data as CFData),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
          decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
      else { return }
      CGImageDestinationAddImage(destination, image, nil)
      CGImageDestinationFinalize(destination)
    }
  }
#endif
