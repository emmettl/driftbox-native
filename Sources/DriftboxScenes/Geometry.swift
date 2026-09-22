#if canImport(Metal)
  import Metal
  import simd

  /// three's perspective camera, as far as the scenes use it: a position, a roll about z, and
  /// a projection. The matrices are what a three vertex shader calls `projectionMatrix` and
  /// `modelViewMatrix` (with the model at the origin), except that depth lands in Metal's
  /// 0...1 rather than GL's -1...1.
  public struct Camera {
    public var position = SIMD3<Float>(0, 0, 5)
    public var roll: Float = 0
    /// What the camera is pointed at, if it is pointed at anything; `roll` turns it about its
    /// own axis when it is not.
    public var target: SIMD3<Float>?
    public var fovDegrees: Float = 75
    public var near: Float = 0.1
    public var far: Float = 1000

    public init() {}

    public func projection(aspect: Float) -> simd_float4x4 {
      let f = 1 / tan(fovDegrees * .pi / 360)
      let range = far - near
      return simd_float4x4(
        SIMD4(f / aspect, 0, 0, 0),
        SIMD4(0, f, 0, 0),
        SIMD4(0, 0, -far / range, -1),
        SIMD4(0, 0, -far * near / range, 0))
    }

    public var view: simd_float4x4 {
      let translate = simd_float4x4(
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
        SIMD4(-position.x, -position.y, -position.z, 1))
      guard let target else {
        let c = cos(-roll)
        let s = sin(-roll)
        let rotate = simd_float4x4(
          SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        return rotate * translate
      }
      // three's `lookAt`: z away from what is looked at, y up, as the camera's own axes.
      let back = simd_normalize(position - target)
      let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
      let up = simd_cross(back, right)
      let rotate = simd_float4x4(
        SIMD4(right.x, up.x, back.x, 0), SIMD4(right.y, up.y, back.y, 0),
        SIMD4(right.z, up.z, back.z, 0), SIMD4(0, 0, 0, 1))
      return rotate * translate
    }
  }

  extension Camera {
    /// three's `unproject`, as the scenes use it: the direction from the eye through a point
    /// on the screen, 0...1 from the bottom left. Any depth on that line gives the same
    /// direction, so the near plane's own convention does not matter here.
    public func ray(through point: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
      let ndc = SIMD4<Float>(point.x * 2 - 1, point.y * 2 - 1, 0.5, 1)
      let world = (projection(aspect: aspect) * view).inverse * ndc
      return simd_normalize(SIMD3(world.x, world.y, world.z) / world.w - position)
    }
  }

  /// three's `Object3D.matrix` for the transforms the scenes use: a scale, a turn about one
  /// axis, then a position — in that order, as three composes them.
  public func modelMatrix(
    position: SIMD3<Float> = .zero, rotationX: Float = 0, scale: Float = 1
  ) -> simd_float4x4 {
    let c = cos(rotationX)
    let s = sin(rotationX)
    return simd_float4x4(
      SIMD4(scale, 0, 0, 0),
      SIMD4(0, c * scale, s * scale, 0),
      SIMD4(0, -s * scale, c * scale, 0),
      SIMD4(position.x, position.y, position.z, 1))
  }

  /// three's `PlaneGeometry`: a grid in the xy plane, with uvs from the bottom left and two
  /// triangles per cell, in three's own vertex and index order.
  public enum Plane {
    public static func build(width: Float, height: Float, segments: SIMD2<Int> = SIMD2(1, 1)) -> (
      positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]
    ) {
      var positions: [SIMD3<Float>] = []
      var uvs: [SIMD2<Float>] = []
      var indices: [UInt32] = []
      let across = max(1, segments.x)
      let down = max(1, segments.y)
      for iy in 0...down {
        let y = Float(iy) / Float(down) * height - height / 2
        for ix in 0...across {
          let x = Float(ix) / Float(across) * width - width / 2
          positions.append(SIMD3(x, -y, 0))
          uvs.append(SIMD2(Float(ix) / Float(across), 1 - Float(iy) / Float(down)))
        }
      }
      for iy in 0..<down {
        for ix in 0..<across {
          let a = UInt32(ix + (across + 1) * iy)
          let b = UInt32(ix + (across + 1) * (iy + 1))
          let c = UInt32(ix + 1 + (across + 1) * (iy + 1))
          let d = UInt32(ix + 1 + (across + 1) * iy)
          indices.append(contentsOf: [a, b, d, b, c, d])
        }
      }
      return (positions, uvs, indices)
    }
  }

  /// three's blending modes, the two the scenes use.
  public enum Blend {
    case normal
    case additive
    case none
  }

  /// A scene made of geometry seen through a camera: the web's three.js scenes. It keeps the
  /// camera and the web's touch energy, clears to a background, and gives a subclass the two
  /// things it builds once — a buffer, and a pipeline for a primitive under a blend.
  open class GeometryScene: Scene {
    open class var id: String { fatalError("a geometry scene names itself") }
    open class var name: String { fatalError("a geometry scene names itself") }
    open class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    open class var background: SIMD3<Float> { SIMD3(0, 0, 0) }

    public let device: MTLDevice
    public let library: MTLLibrary
    public var camera = Camera()
    var lastTime: Double?
    var touchAt = SIMD2<Float>(0.5, 0.5)
    var touchEnergy: Float = 0

    public required init(device: MTLDevice, library: MTLLibrary) throws {
      self.device = device
      self.library = library
      try build()
    }

    /// Geometry and pipelines, once.
    open func build() throws {}

    /// A frame's state from the input — the subclass's uniforms — before `encode`.
    open func advance(_ input: SceneInput, dt: Float, aspect: Float) {}

    /// The draw calls.
    open func encode(_ encoder: MTLRenderCommandEncoder) {}

    public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
      let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
      lastTime = input.time
      if let touch = input.touch { touchAt = touch }
      let down: Float = input.touch == nil ? 0 : 1
      let rate: Float = input.touch == nil ? 1.8 : 6
      touchEnergy += (down - touchEnergy) * min(1, min(dt, 0.05) * rate)
      if input.touch == nil, touchEnergy < 0.001 { touchEnergy = 0 }
      advance(input, dt: dt, aspect: Float(size.x) / Float(max(1, size.y)))

      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      let background = Self.background
      pass.colorAttachments[0].clearColor = MTLClearColor(
        red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
      pass.colorAttachments[0].storeAction = .store
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
      encode(encoder)
      encoder.endEncoding()
    }

    public func pipeline(vertex: String, fragment: String, blend: Blend) throws -> MTLRenderPipelineState {
      let descriptor = MTLRenderPipelineDescriptor()
      guard let vertexFunction = library.makeFunction(name: vertex),
        let fragmentFunction = library.makeFunction(name: fragment)
      else { throw SceneRenderer.SceneError.missingFunction("\(vertex), \(fragment)", library.functionNames) }
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragmentFunction
      let colour = descriptor.colorAttachments[0]!
      colour.pixelFormat = .bgra8Unorm
      switch blend {
      case .none:
        break
      case .normal:
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      case .additive:
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.destinationRGBBlendFactor = .one
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .one
      }
      return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func buffer<T>(_ values: [T]) -> MTLBuffer {
      values.withUnsafeBytes { raw in
        device.makeBuffer(bytes: raw.baseAddress!, length: max(1, raw.count), options: .storageModeShared)!
      }
    }
  }

  extension GeometryScene {
    /// What every geometry vertex function starts from.
    static let preamble = """

      struct CameraUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
      };

      """
  }
#endif
