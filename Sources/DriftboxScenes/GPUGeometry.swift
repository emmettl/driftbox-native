import DriftboxGPU
import Foundation

/// A scene made of geometry seen through a camera, on the GPU layer: the web's three.js scenes.
/// The Metal `GeometryScene`, moved across. It keeps the camera and the web's touch energy, clears
/// to a background, and gives a subclass the two things it builds once — buffers, and pipelines
/// for a primitive under a blend — and a pass to draw them in.
///
/// Every target the layer draws into carries depth and every pass clears it, so a scene turns
/// depth on for a pipeline by asking for it and leaves it off by not.
open class GPUGeometryScene: GPUScene {
  open class var id: String { fatalError("a geometry scene names itself") }
  open class var name: String { fatalError("a geometry scene names itself") }
  open class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  open class var background: SIMD3<Float> { SIMD3(0, 0, 0) }

  public let device: any GPUDevice
  public var camera = Camera()
  /// The target's size in pixels this frame, which `sprite.glsl` sizes sprites against.
  public private(set) var viewport = SIMD2<Float>(1, 1)
  var lastTime: Double?
  public private(set) var touchAt = SIMD2<Float>(0.5, 0.5)
  public private(set) var touchEnergy: Float = 0

  public required init(device: any GPUDevice) throws {
    self.device = device
    try build()
  }

  /// Geometry and pipelines, once.
  open func build() throws {}

  /// A frame's state from the input — the subclass's uniforms — before `encode`.
  open func advance(_ input: SceneInput, dt: Float, aspect: Float) {}

  /// The draw calls.
  open func encode(_ pass: any GPUPass) {}

  public func draw(_ input: SceneInput, into target: any GPUTarget, on device: any GPUDevice) {
    let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
    lastTime = input.time
    if let touch = input.touch { touchAt = touch }
    let down: Float = input.touch == nil ? 0 : 1
    let rate: Float = input.touch == nil ? 1.8 : 6
    touchEnergy += (down - touchEnergy) * min(1, min(dt, 0.05) * rate)
    if input.touch == nil, touchEnergy < 0.001 { touchEnergy = 0 }
    viewport = SIMD2(Float(target.width), Float(max(1, target.height)))
    advance(input, dt: dt, aspect: viewport.x / viewport.y)

    let background = Self.background
    var sprites = SpriteUniforms()
    sprites.uViewport = viewport
    device.render(into: target, clear: .colour(SIMD4(background, 1))) { pass in
      pass.setUniforms(sprites, binding: Self.spriteBinding)
      encode(pass)
    }
  }

  /// Where `sprite.glsl`'s block is bound: out of the way of a scene's own, which start at 0.
  public static let spriteBinding = 4
  /// A sprite is six vertices, a quad's two triangles; its instances are the points.
  public static let spriteVertices = 6

  /// A pipeline for `program`, drawing `primitive`s under `blend`, fed by `vertexBuffers`.
  public func pipeline(
    _ program: ShaderProgram, primitive: GPUPrimitive = .triangles, blend: GPUBlend = .none,
    depth: GPUDepth = .none, cull: GPUCull = .none, vertexBuffers: [GPUVertexLayout] = []
  ) throws -> any GPUPipeline {
    try device.makePipeline(
      GPUPipelineDescriptor(
        program: program, primitive: primitive, blend: blend, depth: depth, cull: cull,
        vertexBuffers: vertexBuffers))
  }

  /// A vertex buffer holding `values`, packed as they are in memory.
  public func buffer<T>(_ values: [T]) throws -> any GPUBuffer {
    try values.withUnsafeBytes { try device.makeBuffer($0, kind: .vertex) }
  }

  /// An index buffer of 32-bit indices.
  public func indices(_ values: [UInt32]) throws -> any GPUBuffer {
    try values.withUnsafeBytes { try device.makeBuffer($0, kind: .index) }
  }
}

extension GPUVertexLayout {
  /// A buffer of one value per vertex — or per instance — read at `location`.
  public static func single(_ format: GPUVertexFormat, location: Int, perInstance: Bool = false)
    -> GPUVertexLayout
  {
    GPUVertexLayout(
      stride: format.stride, perInstance: perInstance,
      attributes: [Attribute(location: location, format: format)])
  }
}

extension GPUVertexFormat {
  /// How far apart a Swift array of this format's values lays them out: `SIMD3<Float>` takes the
  /// room of a `SIMD4<Float>`, as Metal's `float3` does.
  public var stride: Int {
    switch self {
    case .float: MemoryLayout<Float>.stride
    case .float2: MemoryLayout<SIMD2<Float>>.stride
    case .float3: MemoryLayout<SIMD3<Float>>.stride
    case .float4: MemoryLayout<SIMD4<Float>>.stride
    }
  }
}
