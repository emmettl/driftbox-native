#if canImport(Metal)
  import DriftboxScenes
  import Metal
  import Testing

  /// Showing a finished frame somewhere else: the arithmetic of fitting one shape inside
  /// another, and then the real thing, read back.
  struct PresentTests {
    @Test func aFrameFitsWithoutDistortion() {
      // The same shape fills exactly.
      #expect(SceneRenderer.fit(SIMD2(1920, 1080), in: SIMD2(960, 540)) == SIMD2(1, 1))
      // Wider than the target: full width, bars above and below.
      #expect(SceneRenderer.fit(SIMD2(1600, 900), in: SIMD2(400, 400)) == SIMD2(1, 0.5625))
      // Taller than the target: full height, bars at the sides.
      #expect(SceneRenderer.fit(SIMD2(400, 800), in: SIMD2(800, 400)) == SIMD2(0.25, 1))
      // Nothing to fit, or nowhere to fit it, shows nothing rather than dividing by zero.
      #expect(SceneRenderer.fit(SIMD2(0, 1080), in: SIMD2(800, 400)) == .zero)
      #expect(SceneRenderer.fit(SIMD2(1920, 1080), in: SIMD2(800, 0)) == .zero)
    }

    /// A widescreen frame into a square view: black above and below, the picture between.
    @Test func aWideFrameIsLetterboxedInASquare() throws {
      guard let device = MTLCreateSystemDefaultDevice() else { return }
      let renderer = try SceneRenderer(device: device, sceneId: "papercities", now: 0)
      func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
      }
      let frame = try texture(320, 180)
      let view = try texture(200, 200)
      // Paper Cities is cream paper edge to edge, so anywhere the frame lands is bright.
      renderer.draw(SceneInput(time: 1, running: true), into: frame)
      renderer.present(frame, into: view)
      renderer.queue.makeCommandBuffer().map { buffer in
        buffer.commit()
        buffer.waitUntilCompleted()
      }
      let bytes = SceneTests.readBack(view)
      func brightness(row: Int) -> Double {
        var total = 0
        for column in 0..<200 {
          let at = (row * 200 + column) * 4
          total += Int(bytes[at]) + Int(bytes[at + 1]) + Int(bytes[at + 2])
        }
        return Double(total) / Double(200 * 3 * 255)
      }
      // 180/320 of 200 is 112.5 rows of picture, centred: bars of about 44 rows each side.
      #expect(brightness(row: 5) == 0, "the top bar is black")
      #expect(brightness(row: 194) == 0, "the bottom bar is black")
      #expect(brightness(row: 100) > 0.3, "the picture is between them")
      #expect(brightness(row: 60) > 0.3, "and reaches toward the bars")
    }
  }
#endif
