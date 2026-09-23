/// One vertex and one fragment shader, in every language a backend might want, and what they
/// expect to be given. Written by `scripts/shaders.mjs` from the GLSL in `shaders/`; nothing here
/// is typed by hand.
public struct ShaderProgram: Sendable {
  public struct Sources: Sendable {
    public var vertex: String
    public var fragment: String

    public init(vertex: String, fragment: String) {
      self.vertex = vertex
      self.fragment = fragment
    }
  }

  /// A uniform block: set with `GPUPass.setUniforms` at its binding, which both stages share.
  public struct Block: Sendable, Equatable {
    public var name: String
    public var binding: Int
    /// The bytes the shaders read, which a backend rounds up to whole sixteen-byte registers where
    /// its API wants them.
    public var size: Int

    public init(name: String, binding: Int, size: Int) {
      self.name = name
      self.binding = binding
      self.size = size
    }
  }

  /// A texture the fragment shader samples, at its binding.
  public struct Texture: Sendable, Equatable {
    public var name: String
    public var binding: Int

    public init(name: String, binding: Int) {
      self.name = name
      self.binding = binding
    }
  }

  /// A vertex attribute the vertex shader reads, at its location.
  public struct Attribute: Sendable, Equatable {
    public var name: String
    public var location: Int
    public var format: GPUVertexFormat

    public init(name: String, location: Int, format: GPUVertexFormat) {
      self.name = name
      self.location = location
      self.format = format
    }
  }

  public var name: String
  /// Metal Shading Language 2.1. The entry points are `<name>Vertex` and `<name>Fragment`.
  public var metal: Sources
  /// HLSL for shader model 5, Direct3D 11's. The entry points are `main`.
  public var hlsl: Sources
  /// GLSL ES 3.0, with depth converted from 0...1 to OpenGL's -1...1. The entry points are `main`.
  public var essl: Sources
  public var blocks: [Block]
  public var textures: [Texture]
  public var attributes: [Attribute]

  public init(
    name: String, metal: Sources, hlsl: Sources, essl: Sources, blocks: [Block], textures: [Texture],
    attributes: [Attribute]
  ) {
    self.name = name
    self.metal = metal
    self.hlsl = hlsl
    self.essl = essl
    self.blocks = blocks
    self.textures = textures
    self.attributes = attributes
  }
}

/// A Swift struct written by `scripts/shaders.mjs` from a uniform block, member for member at the
/// offsets the shaders read them from.
public protocol UniformBlock: Sendable {
  init()
  /// The bytes the shaders read, which may be more than the struct's.
  static var blockSize: Int { get }
  /// Every member, where Swift put it and where the shaders read it: the two must agree, and a
  /// test holds every generated block to it.
  static var layout: [(member: String, swift: Int?, shader: Int)] { get }
}
