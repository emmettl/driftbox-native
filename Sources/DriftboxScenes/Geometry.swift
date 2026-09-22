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
      let c = cos(-roll)
      let s = sin(-roll)
      let rotate = simd_float4x4(
        SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
      let translate = simd_float4x4(
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
        SIMD4(-position.x, -position.y, -position.z, 1))
      return rotate * translate
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
