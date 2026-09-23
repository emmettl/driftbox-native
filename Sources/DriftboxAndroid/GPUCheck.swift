#if os(Android)
  import DriftboxGPU
  import DriftboxGPUGLES

  /// The GPU contract, on the phone's own GPU.
  ///
  /// `GPUContractTests` is what every backend is held to, and it runs the OpenGL ES backend on
  /// Linux, against Mesa's software rasteriser. A phone's GPU is not that, and its driver is its
  /// own; but Swift Testing does not run on a phone yet — its Android library needs the dynamic
  /// runtime, which the installer's arm64 build cannot link. So the contract's checks are here
  /// again, one for one, with its inputs and the pixels it expects, drawn with the same generated
  /// programs, which the app build compiles in from the tests. A check changed there is changed here.
  enum GPUCheck {
    static func run() -> String {
      var lines: [String] = []
      let device: GLESDevice
      do {
        device = try GLESDevice()
      } catch {
        return "FAIL no OpenGL ES device: \(error)"
      }
      lines.append("on \(device.renderer)")
      let checks: [(String, (GLESDevice, inout [String]) throws -> Void)] = [
        ("a clear is the colour asked for", clear),
        ("the first row is the top", firstRowIsTheTop),
        ("attributes and uniforms draw a shape", attributesAndUniforms),
        ("the nearer wins whatever the order", nearerWins),
        ("blends are three.js's", blends),
        ("sprites are instanced quads", sprites),
        ("a texture is the right way up", textureRightWayUp),
        ("a buffer written again draws what it holds", bufferWrittenAgain),
      ]
      for (name, check) in checks {
        var failures: [String] = []
        do { try check(device, &failures) } catch { failures.append("threw \(error)") }
        lines.append(failures.isEmpty ? "PASS \(name)" : "FAIL \(name): \(failures.joined(separator: "; "))")
      }
      return lines.joined(separator: "\n")
    }

    // MARK: - The checks, as GPUContractTests has them

    static func clear(_ device: GLESDevice, _ failures: inout [String]) throws {
      let target = try device.makeTarget(width: 8, height: 8)
      device.render(into: target, clear: .colour(SIMD4(0.2, 0.4, 0.6, 1))) { _ in }
      let read = try device.readPixels(target)
      expect(read.count == 8 * 8 * 4, "\(read.count) bytes", &failures)
      expect(pixel(read, 3, 5, width: 8), SIMD4(51, 102, 153, 255), within: 1, "the clear", &failures)
    }

    static func firstRowIsTheTop(_ device: GLESDevice, _ failures: inout [String]) throws {
      let target = try device.makeTarget(width: 16, height: 16)
      let pipeline = try device.makePipeline(GPUPipelineDescriptor(program: .gradient))
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.draw(vertexCount: 3)
      }
      let read = try device.readPixels(target)
      let topLeft = pixel(read, 0, 0, width: 16)
      let bottomRight = pixel(read, 15, 15, width: 16)
      expect(topLeft.x < 16 && topLeft.y > 240, "top left \(topLeft)", &failures)
      expect(bottomRight.x > 240 && bottomRight.y < 16, "bottom right \(bottomRight)", &failures)
    }

    static func attributesAndUniforms(_ device: GLESDevice, _ failures: inout [String]) throws {
      let target = try device.makeTarget(width: 16, height: 16)
      let pipeline = try device.makePipeline(flat(depth: .none, blend: .none))
      let buffer = try vertices(device, square(z: 0.5))
      var uniforms = FlatUniforms()
      uniforms.colour = SIMD4(1, 0.5, 0, 1)
      uniforms.transform = Matrix4(
        SIMD4(0.5, 0, 0, 0), SIMD4(0, 0.5, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-0.5, 0, 0, 1))
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(buffer, slot: 0)
        pass.draw(vertexCount: 6)
      }
      let read = try device.readPixels(target)
      expect(pixel(read, 4, 8, width: 16), SIMD4(255, 128, 0, 255), "inside", &failures)
      expect(pixel(read, 12, 8, width: 16), SIMD4(0, 0, 0, 255), "to the right", &failures)
      expect(pixel(read, 4, 1, width: 16), SIMD4(0, 0, 0, 255), "above", &failures)
    }

    static func nearerWins(_ device: GLESDevice, _ failures: inout [String]) throws {
      let pipeline = try device.makePipeline(flat(depth: .testAndWrite, blend: .none))
      let near = try vertices(device, corners(z: 0.3))
      let far = try vertices(device, corners(z: 0.7))
      let indices = try [UInt32(0), 1, 2, 0, 2, 3].withUnsafeBytes { try device.makeBuffer($0, kind: .index) }
      for nearFirst in [true, false] {
        let target = try device.makeTarget(width: 8, height: 8)
        let order =
          nearFirst
          ? [(near, SIMD4<Float>(1, 0, 0, 1)), (far, SIMD4<Float>(0, 1, 0, 1))]
          : [(far, SIMD4<Float>(0, 1, 0, 1)), (near, SIMD4<Float>(1, 0, 0, 1))]
        device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
          pass.setPipeline(pipeline)
          for (buffer, colour) in order {
            var uniforms = FlatUniforms()
            uniforms.colour = colour
            pass.setUniforms(uniforms, binding: 0)
            pass.setVertexBuffer(buffer, slot: 0)
            pass.drawIndexed(indices, count: 6, instanceCount: 1)
          }
        }
        let got = pixel(try device.readPixels(target), 4, 4, width: 8)
        expect(got, SIMD4(255, 0, 0, 255), nearFirst ? "near first" : "far first", &failures)
      }
    }

    static func blends(_ device: GLESDevice, _ failures: inout [String]) throws {
      let square = try vertices(device, square(z: 0.5))
      for (blend, expected) in [
        (GPUBlend.none, SIMD4(255, 0, 0, 128)), (.normal, SIMD4(128, 0, 51, 255)),
        (.additive, SIMD4(128, 0, 102, 255)),
      ] {
        let pipeline = try device.makePipeline(flat(depth: .none, blend: blend))
        let target = try device.makeTarget(width: 4, height: 4)
        var uniforms = FlatUniforms()
        uniforms.colour = SIMD4(1, 0, 0, 0.5)
        device.render(into: target, clear: .colour(SIMD4(0, 0, 0.4, 1))) { pass in
          pass.setPipeline(pipeline)
          pass.setUniforms(uniforms, binding: 0)
          pass.setVertexBuffer(square, slot: 0)
          pass.draw(vertexCount: 6)
        }
        expect(pixel(try device.readPixels(target), 2, 2, width: 4), expected, "\(blend)", &failures)
      }
    }

    static func sprites(_ device: GLESDevice, _ failures: inout [String]) throws {
      let layout = GPUVertexLayout(
        stride: 32, perInstance: true,
        attributes: [
          .init(location: 0, format: .float2, offset: 0), .init(location: 1, format: .float4, offset: 16),
        ])
      let pipeline = try device.makePipeline(
        GPUPipelineDescriptor(program: .sprites, vertexBuffers: [layout]))
      let buffer = try vertices(
        device,
        [
          SIMD4(-0.5, -0.5, 0, 0), SIMD4(1, 0, 0, 1),
          SIMD4(0.5, 0.5, 0, 0), SIMD4(0, 1, 0, 1),
          SIMD4(0.5, -0.5, 0, 0), SIMD4(0, 0, 1, 1),
        ])
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
      expect(pixel(read, 8, 24, width: 32), SIMD4(255, 0, 0, 255), "bottom left is the first", &failures)
      expect(pixel(read, 24, 8, width: 32), SIMD4(0, 255, 0, 255), "top right is the second", &failures)
      expect(pixel(read, 24, 24, width: 32), SIMD4(0, 0, 255, 255), "bottom right is the third", &failures)
      expect(pixel(read, 8, 8, width: 32), SIMD4(0, 0, 0, 255), "top left has none", &failures)
      expect(pixel(read, 4, 28, width: 32), SIMD4(0, 0, 0, 255), "a sprite is round", &failures)
    }

    static func textureRightWayUp(_ device: GLESDevice, _ failures: inout [String]) throws {
      let pixels: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
      let texture = try pixels.withUnsafeBytes { try device.makeTexture(width: 2, height: 2, pixels: $0) }
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
      expect(pixel(read, 0, 0, width: 16), SIMD4(255, 0, 0, 255), within: 8, "top left red", &failures)
      expect(pixel(read, 15, 0, width: 16), SIMD4(0, 255, 0, 255), within: 8, "top right green", &failures)
      expect(pixel(read, 0, 15, width: 16), SIMD4(0, 0, 255, 255), within: 8, "bottom left blue", &failures)
      expect(
        pixel(read, 15, 15, width: 16), SIMD4(255, 255, 255, 255), within: 8, "bottom right white", &failures)

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
      expect(
        presented.y > 230 && presented.x < 25, "the gradient's top left, presented: \(presented)", &failures)
    }

    static func bufferWrittenAgain(_ device: GLESDevice, _ failures: inout [String]) throws {
      let pipeline = try device.makePipeline(flat(depth: .none, blend: .none))
      let buffer = try vertices(device, square(z: 0.5).map { SIMD4($0.x - 3, $0.y, $0.z, $0.w) })
      try square(z: 0.5).withUnsafeBytes { try buffer.update($0) }
      let target = try device.makeTarget(width: 4, height: 4)
      var uniforms = FlatUniforms()
      uniforms.colour = SIMD4(0, 1, 0, 1)
      device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
        pass.setPipeline(pipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(buffer, slot: 0)
        pass.draw(vertexCount: 6)
      }
      expect(
        pixel(try device.readPixels(target), 2, 2, width: 4), SIMD4(0, 255, 0, 255), "rewritten", &failures)
      do {
        try (square(z: 0.5) + square(z: 0.5)).withUnsafeBytes { try buffer.update($0) }
        failures.append("an update longer than the buffer was not refused")
      } catch {}
    }

    // MARK: - As GPUContractTests has them

    static func flat(depth: GPUDepth, blend: GPUBlend) -> GPUPipelineDescriptor {
      GPUPipelineDescriptor(
        program: .flat, blend: blend, depth: depth,
        vertexBuffers: [GPUVertexLayout(stride: 16, attributes: [.init(location: 0, format: .float3)])])
    }

    static func square(z: Float) -> [SIMD4<Float>] {
      [
        SIMD4(-1, -1, z, 1), SIMD4(1, -1, z, 1), SIMD4(1, 1, z, 1),
        SIMD4(-1, -1, z, 1), SIMD4(1, 1, z, 1), SIMD4(-1, 1, z, 1),
      ]
    }

    static func corners(z: Float) -> [SIMD4<Float>] {
      [SIMD4(-1, -1, z, 1), SIMD4(1, -1, z, 1), SIMD4(1, 1, z, 1), SIMD4(-1, 1, z, 1)]
    }

    static func vertices(_ device: GLESDevice, _ values: [SIMD4<Float>]) throws -> any GPUBuffer {
      try values.withUnsafeBytes { try device.makeBuffer($0, kind: .vertex) }
    }

    /// A target's pixel at `(x, y)` from the top left, as red, green, blue, alpha.
    static func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> SIMD4<Int> {
      let at = (y * width + x) * 4
      return SIMD4(Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at]), Int(bytes[at + 3]))
    }

    static func expect(_ passed: Bool, _ what: String, _ failures: inout [String]) {
      if !passed { failures.append(what) }
    }

    static func expect(
      _ got: SIMD4<Int>, _ wanted: SIMD4<Int>, within: Int = 2, _ what: String, _ failures: inout [String]
    ) {
      let d = got &- wanted
      if abs(d.x) > within || abs(d.y) > within || abs(d.z) > within || abs(d.w) > within {
        failures.append("\(what): \(got), not \(wanted)")
      }
    }
  }
#endif
