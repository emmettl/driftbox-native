/// What the scenes ask of a GPU, and all of it: buffers, textures, pipelines, and passes that draw
/// into a target. Each platform answers it with a backend of its own — Metal, Direct3D 11,
/// OpenGL ES 3.0 — and nothing here says more than all three can do the same way.
///
/// That rule decides the shape. There are no points with a size, since Direct3D draws a point one
/// pixel wide whatever it is told: a sprite is an instanced quad on every backend, and so draws the
/// same pixels on every backend. There is no storage buffer, since OpenGL ES 3.0 has none: a shader
/// reads what it is given through its uniform blocks, its textures, and vertex attributes stepping
/// per vertex or per instance. Colour is always 8-bit BGRA and depth 32-bit float.
///
/// Conventions, which every backend keeps: clip space has y up and depth 0...1, as Metal's and
/// Direct3D's do (the OpenGL ES backend's shaders are converted to its -1...1); a target's first
/// row is its top; texture coordinates start at the top left.
public protocol GPUDevice: AnyObject {
  var backend: GPUBackend { get }

  func makeBuffer(_ bytes: UnsafeRawBufferPointer, kind: GPUBufferKind) throws -> any GPUBuffer
  /// A texture to sample, `width` by `height` BGRA pixels, rows from the top.
  func makeTexture(width: Int, height: Int, pixels: UnsafeRawBufferPointer?) throws -> any GPUTexture
  /// Somewhere to draw off screen: colour, which can be sampled afterwards, and depth.
  func makeTarget(width: Int, height: Int) throws -> any GPUTarget
  func makePipeline(_ descriptor: GPUPipelineDescriptor) throws -> any GPUPipeline

  /// One pass into `target`: cleared to `clear` first if there is one, then whatever `draw` does.
  func render(into target: any GPUTarget, clear: GPUClear, _ draw: (any GPUPass) throws -> Void) rethrows

  /// What `target` holds, as BGRA bytes, rows from the top. Waits for everything drawn into it.
  func readPixels(_ target: any GPUTarget) throws -> [UInt8]
}

public enum GPUBackend: Sendable {
  case metal
  case direct3D11
  case openGLES
}

public enum GPUBufferKind: Sendable {
  case vertex
  case index
}

/// A buffer of vertices or 32-bit indices, which can be written again, whole, between frames.
public protocol GPUBuffer: AnyObject {
  var length: Int { get }
  /// Replace the contents. Longer than the buffer was made is an error.
  func update(_ bytes: UnsafeRawBufferPointer) throws
}

public protocol GPUTexture: AnyObject {
  var width: Int { get }
  var height: Int { get }
  /// Replace every pixel: `width` by `height` BGRA, rows from the top.
  func update(_ pixels: UnsafeRawBufferPointer) throws
}

/// Somewhere to draw: a colour texture and a depth buffer the same size.
public protocol GPUTarget: AnyObject {
  var width: Int { get }
  var height: Int { get }
  /// The colour, to sample in another pass once this one is done.
  var colour: any GPUTexture { get }
}

/// Somewhere on screen to draw: a window's swap chain, a view's layer. Made by a backend from
/// whatever its platform calls a window, which is why making one is not in `GPUDevice`; drawn into
/// and shown through this, which is the same everywhere.
public protocol GPUSurface: AnyObject {
  var width: Int { get }
  var height: Int { get }
  /// Follow the window to a new size, in pixels. The next target is that size.
  func resize(width: Int, height: Int) throws
  /// The target this frame is drawn into. Drawn into and presented once per frame.
  func target() throws -> any GPUTarget
  /// Show what has been drawn, at the display's next refresh, waiting for it if the one before
  /// is still showing on swap-chain shells. A toolkit-driven shell instead schedules each frame
  /// itself; its surface copies into the current toolkit drawable without waiting or swapping.
  func present() throws
}

public protocol GPUPipeline: AnyObject {
  var descriptor: GPUPipelineDescriptor { get }
}

/// What a pass can be asked to do. Uniforms, buffers and textures stay set until set again, as they
/// do on every backend; a new pipeline keeps them.
public protocol GPUPass {
  func setPipeline(_ pipeline: any GPUPipeline)
  /// Fill the uniform block at `binding`, for both stages, from `bytes`.
  func setUniforms(_ bytes: UnsafeRawBufferPointer, binding: Int)
  /// The buffer the pipeline's vertex layout `slot` reads from.
  func setVertexBuffer(_ buffer: any GPUBuffer, slot: Int)
  func setTexture(_ texture: any GPUTexture, binding: Int)
  func draw(vertexCount: Int, instanceCount: Int)
  /// `count` 32-bit indices from `indices`.
  func drawIndexed(_ indices: any GPUBuffer, count: Int, instanceCount: Int)
}

extension GPUPass {
  /// A generated uniform struct, at its block's binding.
  public func setUniforms<Block: UniformBlock>(_ block: Block, binding: Int) {
    withUnsafeBytes(of: block) { setUniforms($0, binding: binding) }
  }

  public func draw(vertexCount: Int) { draw(vertexCount: vertexCount, instanceCount: 1) }
}

public enum GPUClear: Sendable {
  /// Keep what is there.
  case none
  /// Colour to `rgba`, 0...1, and depth to the far plane.
  case colour(SIMD4<Float>)
}

// MARK: - Pipelines

public struct GPUPipelineDescriptor: Sendable {
  public var program: ShaderProgram
  public var primitive: GPUPrimitive
  public var blend: GPUBlend
  public var depth: GPUDepth
  public var cull: GPUCull
  /// The vertex buffers, by slot, and which attribute each part of them feeds.
  public var vertexBuffers: [GPUVertexLayout]

  public init(
    program: ShaderProgram, primitive: GPUPrimitive = .triangles, blend: GPUBlend = .none,
    depth: GPUDepth = .none, cull: GPUCull = .none,
    vertexBuffers: [GPUVertexLayout] = []
  ) {
    self.program = program
    self.primitive = primitive
    self.blend = blend
    self.depth = depth
    self.cull = cull
    self.vertexBuffers = vertexBuffers
  }

  /// Why the layout does not give the program what it reads, or nil when it does: every attribute
  /// fed, at its location, in its format. Every backend asks before it builds a pipeline, so a
  /// mismatch is an error where it is made rather than a shape drawn from the wrong bytes.
  public var mismatch: String? {
    let fed = vertexBuffers.flatMap(\.attributes)
    for attribute in program.attributes {
      guard let given = fed.first(where: { $0.location == attribute.location }) else {
        return
          "\(program.name) reads \(attribute.name) at location \(attribute.location), and nothing feeds it"
      }
      if given.format != attribute.format {
        return "\(program.name) reads \(attribute.name) as \(attribute.format), and is fed \(given.format)"
      }
    }
    return nil
  }
}

public enum GPUPrimitive: Sendable {
  case triangles
  case triangleStrip
  case lines
  case lineStrip
}

/// What a pipeline does with the target's depth, nearer winning where it tests: three's
/// `depthTest` and `depthWrite`, as the combinations of them the scenes use.
public enum GPUDepth: Sendable {
  /// Neither: drawn wherever it lands, and hides nothing drawn after it.
  case none
  /// Hidden behind what is nearer, but hiding nothing itself: for something transparent among
  /// solid things, which is what three's `depthWrite={false}` is for.
  case test
  /// Hidden behind what is nearer, and hiding what is further: for solid things.
  case testAndWrite
}

/// Which faces of a triangle are not drawn. A triangle's front is the side from which its corners
/// run counter-clockwise as it appears on the target: three's front and OpenGL's, since every mesh
/// the scenes draw was made for three. Direct3D and Metal default to the other way round, so their
/// backends say so.
public enum GPUCull: Sendable {
  case none
  case back
  case front
}

/// three.js's blending modes, the ones the scenes use, and the canvas's multiply.
public enum GPUBlend: Sendable {
  case none
  /// Straight alpha over what is there.
  case normal
  /// Added to what is there, weighted by alpha.
  case additive
  /// What is there, multiplied by the colour drawn, its alpha left as it was. Alpha plays no part
  /// in the multiplication, so a shader drawing a straight-alpha colour this way gives the colour
  /// mixed toward white by how little it covers: `mix(1, colour, alpha)`, which is the canvas's
  /// `multiply` over an opaque page.
  case multiply
}

public enum GPUVertexFormat: Sendable, Equatable {
  case float
  case float2
  case float3
  case float4

  public var size: Int {
    switch self {
    case .float: 4
    case .float2: 8
    case .float3: 12
    case .float4: 16
    }
  }
}

/// One vertex buffer as the pipeline reads it: how far apart its elements are, whether it steps
/// per vertex or per instance, and the attributes packed in each element.
public struct GPUVertexLayout: Sendable {
  public struct Attribute: Sendable {
    public var location: Int
    public var format: GPUVertexFormat
    public var offset: Int

    public init(location: Int, format: GPUVertexFormat, offset: Int = 0) {
      self.location = location
      self.format = format
      self.offset = offset
    }
  }

  public var stride: Int
  public var perInstance: Bool
  public var attributes: [Attribute]

  public init(stride: Int, perInstance: Bool = false, attributes: [Attribute]) {
    self.stride = stride
    self.perInstance = perInstance
    self.attributes = attributes
  }
}

public struct GPUError: Error, CustomStringConvertible {
  public var description: String
  public init(_ description: String) { self.description = description }
}
