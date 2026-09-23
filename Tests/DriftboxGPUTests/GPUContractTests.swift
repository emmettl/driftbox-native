import DriftboxGPU
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
#elseif canImport(Metal)
  import DriftboxGPUMetal
  import Metal
#endif

/// What every backend must do the same way, held to one set of tests: whichever backends this
/// platform has run all of them. The scenes are written against these conventions, so a backend
/// that passes draws a scene as every other does.
///
/// Direct3D runs on WARP, Windows' software rasteriser, so that the pixels are the same on every
/// machine and there is a device on one with no graphics card, as a CI runner has none. Metal runs
/// on the machine's own GPU, where it has one.
enum Backends {
  static func all() throws -> [any GPUDevice] {
    #if os(Windows)
      return [try D3D11Device(driver: .software)]
    #elseif canImport(Metal)
      return MTLCreateSystemDefaultDevice() == nil ? [] : [try MetalDevice()]
    #else
      return []
    #endif
  }
}

/// A target's pixel at `(x, y)` from the top left, as red, green, blue, alpha.
func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> SIMD4<Int> {
  let at = (y * width + x) * 4
  return SIMD4(Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at]), Int(bytes[at + 3]))
}

func close(_ a: SIMD4<Int>, _ b: SIMD4<Int>, within: Int = 2) -> Bool {
  let d = a &- b
  return abs(d.x) <= within && abs(d.y) <= within && abs(d.z) <= within && abs(d.w) <= within
}

func bytes<T>(_ values: [T], _ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
  try values.withUnsafeBytes(body)
}

struct LayoutTests {
  /// Every uniform block the generator wrote is where the shaders read it, member for member.
  @Test func everyBlockIsLaidOutAsTheShadersReadIt() {
    let blocks: [any UniformBlock.Type] = [
      LayoutUniforms.self, FlatUniforms.self, SpriteUniforms.self, PresentUniforms.self,
    ]
    for block in blocks {
      for (member, swift, shader) in block.layout {
        #expect(swift == shader, "\(block).\(member): Swift at \(swift ?? -1), the shaders at \(shader)")
      }
    }
  }

  @Test func matricesApplyTheRightHandOneFirst() {
    let scale = Matrix4(SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 2, 0), SIMD4(0, 0, 0, 1))
    let move = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(3, 0, 0, 1))
    #expect((move * scale) * SIMD4(1, 1, 1, 1) == SIMD4(5, 2, 2, 1))
    #expect((scale * move) * SIMD4(1, 1, 1, 1) == SIMD4(8, 2, 2, 1))
    #expect(move.transpose.transpose == move)
    #expect(Matrix4.identity * move == move)
  }

  /// A layout that does not give the program what it reads is refused where the pipeline is made.
  @Test func aPipelineThatIsNotFedIsRefused() throws {
    let unfed = GPUPipelineDescriptor(program: .flat)
    #expect(unfed.mismatch != nil)
    let wrong = GPUPipelineDescriptor(
      program: .flat,
      vertexBuffers: [GPUVertexLayout(stride: 8, attributes: [.init(location: 0, format: .float2)])])
    #expect(wrong.mismatch?.contains("float2") == true)
    for device in try Backends.all() {
      #expect(throws: GPUError.self) { try device.makePipeline(unfed) }
    }
  }
}

struct GPUContractTests {
  @Test func aClearIsTheColourAskedFor() throws {
    for device in try Backends.all() {
      let target = try device.makeTarget(width: 8, height: 8)
      device.render(into: target, clear: .colour(SIMD4(0.2, 0.4, 0.6, 1))) { _ in }
      let read = try device.readPixels(target)
      #expect(read.count == 8 * 8 * 4)
      #expect(close(pixel(read, 3, 5, width: 8), SIMD4(51, 102, 153, 255), within: 1))
    }
  }

  /// Clip space has y up, and the first row read back is the top: a gradient of `vUv`, which runs
  /// from the bottom left, is green along the top and red along the right.
  @Test func theFirstRowIsTheTop() throws {
    for device in try Backends.all() {
      let target = try device.makeTarget(width: 16, height: 16)
      let pipeline = try device.makePipeline(GPUPipelineDescriptor(program: .gradient))
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.draw(vertexCount: 3)
      }
      let read = try device.readPixels(target)
      let topLeft = pixel(read, 0, 0, width: 16)
      let bottomRight = pixel(read, 15, 15, width: 16)
      #expect(topLeft.x < 16 && topLeft.y > 240, "top left \(topLeft)")
      #expect(bottomRight.x > 240 && bottomRight.y < 16, "bottom right \(bottomRight)")
    }
  }

  /// Positions from a vertex buffer through a matrix, in a colour from a uniform block: the left
  /// half of the target, shifted by the matrix, and nothing else.
  @Test func attributesAndUniformsDrawAShape() throws {
    for device in try Backends.all() {
      let target = try device.makeTarget(width: 16, height: 16)
      let pipeline = try device.makePipeline(Self.flat(depth: false, blend: .none))
      let square: [SIMD4<Float>] = Self.square(z: 0.5)
      var buffer: (any GPUBuffer)!
      try bytes(square) { buffer = try device.makeBuffer($0, kind: .vertex) }
      var uniforms = FlatUniforms()
      uniforms.colour = SIMD4(1, 0.5, 0, 1)
      // Half size and half a screen left: the square covers the left half of the target's middle.
      uniforms.transform = Matrix4(
        SIMD4(0.5, 0, 0, 0), SIMD4(0, 0.5, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-0.5, 0, 0, 1))
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(buffer, slot: 0)
        pass.draw(vertexCount: 6)
      }
      let read = try device.readPixels(target)
      #expect(close(pixel(read, 4, 8, width: 16), SIMD4(255, 128, 0, 255)))
      #expect(close(pixel(read, 12, 8, width: 16), SIMD4(0, 0, 0, 255)))
      #expect(close(pixel(read, 4, 1, width: 16), SIMD4(0, 0, 0, 255)))
    }
  }

  /// With depth on, the nearer of two squares wins whichever is drawn first, drawn from indices.
  @Test func theNearerWinsWhateverTheOrder() throws {
    for device in try Backends.all() {
      let pipeline = try device.makePipeline(Self.flat(depth: true, blend: .none))
      var near: (any GPUBuffer)!
      var far: (any GPUBuffer)!
      var indices: (any GPUBuffer)!
      try bytes(Self.corners(z: 0.3)) { near = try device.makeBuffer($0, kind: .vertex) }
      try bytes(Self.corners(z: 0.7)) { far = try device.makeBuffer($0, kind: .vertex) }
      try bytes([UInt32(0), 1, 2, 0, 2, 3]) { indices = try device.makeBuffer($0, kind: .index) }
      for nearFirst in [true, false] {
        let target = try device.makeTarget(width: 8, height: 8)
        device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
          pass.setPipeline(pipeline)
          for (buffer, colour) in nearFirst
            ? [(near!, SIMD4<Float>(1, 0, 0, 1)), (far!, SIMD4<Float>(0, 1, 0, 1))]
            : [(far!, SIMD4<Float>(0, 1, 0, 1)), (near!, SIMD4<Float>(1, 0, 0, 1))]
          {
            var uniforms = FlatUniforms()
            uniforms.colour = colour
            pass.setUniforms(uniforms, binding: 0)
            pass.setVertexBuffer(buffer, slot: 0)
            pass.drawIndexed(indices, count: 6, instanceCount: 1)
          }
        }
        #expect(close(pixel(try device.readPixels(target), 4, 4, width: 8), SIMD4(255, 0, 0, 255)))
      }
    }
  }

  /// three's blending: none replaces, normal lays straight alpha over, additive adds.
  @Test func blendsAreThreeJs() throws {
    for device in try Backends.all() {
      var square: (any GPUBuffer)!
      try bytes(Self.square(z: 0.5)) { square = try device.makeBuffer($0, kind: .vertex) }
      let background = SIMD4<Float>(0, 0, 0.4, 1)
      for (blend, expected) in [
        (GPUBlend.none, SIMD4(255, 0, 0, 128)), (.normal, SIMD4(128, 0, 51, 255)),
        (.additive, SIMD4(128, 0, 102, 255)),
      ] {
        let pipeline = try device.makePipeline(Self.flat(depth: false, blend: blend))
        let target = try device.makeTarget(width: 4, height: 4)
        var uniforms = FlatUniforms()
        uniforms.colour = SIMD4(1, 0, 0, 0.5)
        device.render(into: target, clear: .colour(background)) { pass in
          pass.setPipeline(pipeline)
          pass.setUniforms(uniforms, binding: 0)
          pass.setVertexBuffer(square, slot: 0)
          pass.draw(vertexCount: 6)
        }
        let got = pixel(try device.readPixels(target), 2, 2, width: 4)
        #expect(close(got, expected), "\(blend): \(got)")
      }
    }
  }

  /// Sprites are quads, instanced: each one's centre and colour step per instance, and what lies
  /// outside the circle cut from the quad is left alone.
  @Test func spritesAreInstancedQuads() throws {
    for device in try Backends.all() {
      let layout = GPUVertexLayout(
        stride: 32, perInstance: true,
        attributes: [
          .init(location: 0, format: .float2, offset: 0), .init(location: 1, format: .float4, offset: 16),
        ])
      let pipeline = try device.makePipeline(
        GPUPipelineDescriptor(program: .sprites, vertexBuffers: [layout]))
      // Centre (padded to sixteen bytes) and colour, per sprite.
      let instances: [SIMD4<Float>] = [
        SIMD4(-0.5, -0.5, 0, 0), SIMD4(1, 0, 0, 1),
        SIMD4(0.5, 0.5, 0, 0), SIMD4(0, 1, 0, 1),
        SIMD4(0.5, -0.5, 0, 0), SIMD4(0, 0, 1, 1),
      ]
      var buffer: (any GPUBuffer)!
      try bytes(instances) { buffer = try device.makeBuffer($0, kind: .vertex) }
      var uniforms = SpriteUniforms()
      uniforms.radius = SIMD2(0.25, 0.25)
      let target = try device.makeTarget(width: 32, height: 32)
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(buffer, slot: 0)
        pass.draw(vertexCount: 6, instanceCount: 3)
      }
      let read = try device.readPixels(target)
      #expect(close(pixel(read, 8, 24, width: 32), SIMD4(255, 0, 0, 255)), "bottom left is the first")
      #expect(close(pixel(read, 24, 8, width: 32), SIMD4(0, 255, 0, 255)), "top right is the second")
      #expect(close(pixel(read, 24, 24, width: 32), SIMD4(0, 0, 255, 255)), "bottom right is the third")
      #expect(close(pixel(read, 8, 8, width: 32), SIMD4(0, 0, 0, 255)), "and top left has none")
      // The quad's corner, outside its circle.
      #expect(close(pixel(read, 4, 28, width: 32), SIMD4(0, 0, 0, 255)), "a sprite is round")
    }
  }

  /// A texture's first row is its top, and a finished frame presented into a target is the right
  /// way up — the frame drawn in one pass and sampled in the next.
  @Test func aTextureIsTheRightWayUp() throws {
    for device in try Backends.all() {
      // Two by two BGRA, rows from the top: red, green; blue, white.
      let pixels: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
      var texture: (any GPUTexture)!
      try bytes(pixels) { texture = try device.makeTexture(width: 2, height: 2, pixels: $0) }
      let pipeline = try device.makePipeline(
        GPUPipelineDescriptor(program: .present, primitive: .triangleStrip))
      let target = try device.makeTarget(width: 16, height: 16)
      var uniforms = PresentUniforms()
      uniforms.scale = SIMD2(1, 1)
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setTexture(texture, binding: 1)
        pass.draw(vertexCount: 4)
      }
      let read = try device.readPixels(target)
      #expect(close(pixel(read, 0, 0, width: 16), SIMD4(255, 0, 0, 255), within: 8), "top left red")
      #expect(close(pixel(read, 15, 0, width: 16), SIMD4(0, 255, 0, 255), within: 8), "top right green")
      #expect(close(pixel(read, 0, 15, width: 16), SIMD4(0, 0, 255, 255), within: 8), "bottom left blue")
      #expect(
        close(pixel(read, 15, 15, width: 16), SIMD4(255, 255, 255, 255), within: 8), "bottom right white")

      // And a target's colour, drawn in one pass and read in the next, the same way.
      let frame = try device.makeTarget(width: 16, height: 16)
      let gradient = try device.makePipeline(GPUPipelineDescriptor(program: .gradient))
      device.render(into: frame, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(gradient)
        pass.draw(vertexCount: 3)
      }
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setTexture(frame.colour, binding: 1)
        pass.draw(vertexCount: 4)
      }
      let presented = pixel(try device.readPixels(target), 0, 0, width: 16)
      #expect(presented.y > 230 && presented.x < 25, "the gradient's top left, presented: \(presented)")
    }
  }

  /// A buffer written again draws what it now holds.
  @Test func aBufferWrittenAgainDrawsWhatItHolds() throws {
    for device in try Backends.all() {
      let pipeline = try device.makePipeline(Self.flat(depth: false, blend: .none))
      var buffer: (any GPUBuffer)!
      // Off to the left of the screen, where nothing is drawn.
      let offscreen = Self.square(z: 0.5).map { SIMD4($0.x - 3, $0.y, $0.z, $0.w) }
      try bytes(offscreen) { buffer = try device.makeBuffer($0, kind: .vertex) }
      try bytes(Self.square(z: 0.5)) { try buffer.update($0) }
      let target = try device.makeTarget(width: 4, height: 4)
      var uniforms = FlatUniforms()
      uniforms.colour = SIMD4(0, 1, 0, 1)
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(buffer, slot: 0)
        pass.draw(vertexCount: 6)
      }
      #expect(close(pixel(try device.readPixels(target), 2, 2, width: 4), SIMD4(0, 255, 0, 255)))
      #expect(throws: GPUError.self) {
        try bytes(Self.square(z: 0.5) + Self.square(z: 0.5)) { try buffer.update($0) }
      }
    }
  }

  // MARK: - Shapes

  /// The flat program, reading positions from float4s (the fourth ignored) sixteen bytes apart.
  static func flat(depth: Bool, blend: GPUBlend) -> GPUPipelineDescriptor {
    GPUPipelineDescriptor(
      program: .flat, blend: blend, depth: depth,
      vertexBuffers: [GPUVertexLayout(stride: 16, attributes: [.init(location: 0, format: .float3)])])
  }

  /// The whole of clip space as two triangles, at depth `z`.
  static func square(z: Float) -> [SIMD4<Float>] {
    [
      SIMD4(-1, -1, z, 1), SIMD4(1, -1, z, 1), SIMD4(1, 1, z, 1),
      SIMD4(-1, -1, z, 1), SIMD4(1, 1, z, 1), SIMD4(-1, 1, z, 1),
    ]
  }

  /// The same, as four corners for an index buffer.
  static func corners(z: Float) -> [SIMD4<Float>] {
    [SIMD4(-1, -1, z, 1), SIMD4(1, -1, z, 1), SIMD4(1, 1, z, 1), SIMD4(-1, 1, z, 1)]
  }
}

struct PresenterTests {
  @Test func aFrameFitsWithoutDistortion() {
    #expect(Presenter.fit(SIMD2(1920, 1080), in: SIMD2(1080, 1080)) == SIMD2(1, 0.5625))
    #expect(Presenter.fit(SIMD2(1080, 1920), in: SIMD2(1080, 1080)) == SIMD2(0.5625, 1))
    #expect(Presenter.fit(SIMD2(100, 50), in: SIMD2(200, 100)) == SIMD2(1, 1))
    #expect(Presenter.fit(.zero, in: SIMD2(1, 1)) == .zero)
  }

  @Test func aFrameCoversByCroppingTheOverhang() {
    #expect(Presenter.cover(SIMD2(1920, 1080), in: SIMD2(1080, 1080)) == SIMD2(Float(1920) / 1080, 1))
    #expect(Presenter.cover(SIMD2(1080, 1920), in: SIMD2(1080, 1080)) == SIMD2(1, Float(1920) / 1080))
  }

  /// A wide frame presented in a square is letterboxed: black above and below, the frame between.
  @Test func aWideFrameIsLetterboxedInASquare() throws {
    for device in try Backends.all() {
      let frame = try device.makeTarget(width: 32, height: 16)
      device.render(into: frame, clear: .colour(SIMD4(1, 1, 1, 1))) { _ in }
      let square = try device.makeTarget(width: 32, height: 32)
      try Presenter(device: device).present(frame, into: square, on: device)
      let read = try device.readPixels(square)
      #expect(close(pixel(read, 16, 2, width: 32), SIMD4(0, 0, 0, 255)), "a bar above")
      #expect(close(pixel(read, 16, 16, width: 32), SIMD4(255, 255, 255, 255)), "the frame between")
      #expect(close(pixel(read, 16, 29, width: 32), SIMD4(0, 0, 0, 255)), "a bar below")

      try Presenter(device: device).present(frame, into: square, on: device, filling: true)
      #expect(
        close(pixel(try device.readPixels(square), 16, 2, width: 32), SIMD4(255, 255, 255, 255)), "filled")
    }
  }
}

#if os(Windows)
  import DriftboxWin32

  /// A window's swap chain, drawn into as any target is and read back from the buffer about to
  /// be shown: never on screen, since the window is never shown, but a real swap chain for all that.
  @MainActor
  struct SurfaceTests {
    @Test func aSurfaceIsDrawnIntoAndFollowsItsWindow() throws {
      let window = try Win32Window(title: "Driftbox test", width: 320, height: 200, visible: false)
      defer { window.close() }
      #expect(window.width > 0 && window.height > 0)
      let device = try D3D11Device(driver: .software)
      let surface = try device.makeSurface(window: window.handle, width: window.width, height: window.height)
      #expect(surface.width == window.width && surface.height == window.height)

      // A frame's target is let go of before the window resizes, as a loop's local one is.
      do {
        let target = try surface.target()
        #expect(target.width == window.width && target.height == window.height)
        device.render(into: target, clear: .colour(SIMD4(0.2, 0.4, 0.6, 1))) { _ in }
        let read = try device.readPixels(target)
        #expect(close(pixel(read, 20, 12, width: target.width), SIMD4(51, 102, 153, 255), within: 1))
        try surface.present()
        // And one held on to says so, rather than DXGI's "invalid call".
        #expect(throws: GPUError.self) { try surface.resize(width: 64, height: 64) }
      }

      try surface.resize(width: 16, height: 16)
      let target = try surface.target()
      #expect(target.width == 16 && target.height == 16)
      let frame = try device.makeTarget(width: 16, height: 16)
      device.render(into: frame, clear: .colour(SIMD4(0, 1, 0, 1))) { _ in }
      try Presenter(device: device).present(frame, into: target, on: device)
      #expect(close(pixel(try device.readPixels(target), 8, 8, width: 16), SIMD4(0, 255, 0, 255)))
      try surface.present()
      window.pump()
    }
  }
#endif

#if canImport(Metal) && canImport(QuartzCore)
  import QuartzCore

  /// A layer's drawables, drawn into as any target is and read back from the one about to be
  /// shown: never on screen, since the layer is in no window, but real drawables for all that.
  struct MetalSurfaceTests {
    @Test func aSurfaceIsDrawnIntoAndFollowsItsLayer() throws {
      guard MTLCreateSystemDefaultDevice() != nil else { return }
      let device = try MetalDevice()
      let layer = CAMetalLayer()
      let surface = try device.makeSurface(layer: layer, width: 320, height: 200)
      #expect(surface.width == 320 && surface.height == 200)

      let target = try surface.target()
      #expect(target.width == 320 && target.height == 200)
      #expect(try surface.target() === target, "one target a frame, however often it is asked for")
      device.render(into: target, clear: .colour(SIMD4(0.2, 0.4, 0.6, 1))) { _ in }
      #expect(
        close(pixel(try device.readPixels(target), 20, 12, width: 320), SIMD4(51, 102, 153, 255), within: 1))
      try surface.present()
      #expect(try surface.target() !== target, "and a new one the next")
      try surface.present()

      try surface.resize(width: 16, height: 16)
      let resized = try surface.target()
      #expect(resized.width == 16 && resized.height == 16)
      let frame = try device.makeTarget(width: 16, height: 16)
      device.render(into: frame, clear: .colour(SIMD4(0, 1, 0, 1))) { _ in }
      try Presenter(device: device).present(frame, into: resized, on: device)
      #expect(close(pixel(try device.readPixels(resized), 8, 8, width: 16), SIMD4(0, 255, 0, 255)))
      try surface.present()
    }
  }
#endif

/// The backends this platform should have, there: a platform whose backend is missing from the
/// contract tests would pass them all by testing nothing.
struct BackendTests {
  @Test func thisPlatformsBackendIsTested() throws {
    let backends = try Backends.all().map(\.backend)
    #if os(Windows)
      #expect(backends == [.direct3D11])
    #elseif canImport(Metal)
      if MTLCreateSystemDefaultDevice() != nil { #expect(backends == [.metal]) }
    #else
      #expect(backends.isEmpty)
    #endif
  }
}
