#if canImport(Metal)
  import DriftboxGPU
  import Metal
  import simd

  /// The Metal scenes' view of the shared geometry in `Space.swift`: the same camera and model
  /// matrices, as `simd`'s matrices, which is what their uniforms hold. One set of arithmetic,
  /// written once; these go with the Metal scenes.
  extension simd_float4x4 {
    init(_ matrix: Matrix4) {
      self.init(matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3)
    }
  }

  extension Camera {
    public func projection(aspect: Float) -> simd_float4x4 {
      simd_float4x4(projectionMatrix(aspect: aspect))
    }
    public var view: simd_float4x4 { simd_float4x4(viewMatrix) }
  }

  public func modelMatrix(
    position: SIMD3<Float> = .zero, rotationX: Float = 0, scale: Float = 1
  ) -> simd_float4x4 {
    simd_float4x4(Matrix4.model(position: position, rotationX: rotationX, scale: scale))
  }

  public func modelMatrix(position: SIMD3<Float>, rotation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(Matrix4.model(position: position, rotation: rotation))
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
    /// Depth, for the scenes with solid geometry. Every geometry pipeline declares the format
    /// and the pass always carries the texture, so a scene turns depth on by asking for
    /// `depthState` and leaves it off by not — rather than by each scene owning a pass.
    public static let depthFormat = MTLPixelFormat.depth32Float
    var depth: MTLTexture?
    public private(set) lazy var depthState: MTLDepthStencilState? = {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .less
      descriptor.isDepthWriteEnabled = true
      return device.makeDepthStencilState(descriptor: descriptor)
    }()
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
      if depth == nil || depth?.width != target.width || depth?.height != target.height {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: Self.depthFormat, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depth = device.makeTexture(descriptor: descriptor)
      }
      pass.depthAttachment.texture = depth
      pass.depthAttachment.loadAction = .clear
      pass.depthAttachment.clearDepth = 1
      pass.depthAttachment.storeAction = .dontCare
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
      descriptor.depthAttachmentPixelFormat = Self.depthFormat
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
