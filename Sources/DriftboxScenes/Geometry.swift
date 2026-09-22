#if canImport(Metal)
  import Metal
  import simd

  /// three's perspective camera, as far as the scenes use it: a position, a roll about z, and
  /// a projection. The matrices are what a three vertex shader calls `projectionMatrix` and
  /// `modelViewMatrix` (with the model at the origin), except that depth lands in Metal's
  /// 0...1 rather than GL's -1...1.
  /// Its defaults are the web canvas's own — `fov: 60, position: [0, 1.15, 6], near: 0.1,
  /// far: 200` — because a scene that never sets one of them is relying on it.
  public struct Camera {
    public var position = SIMD3<Float>(0, 1.15, 6)
    public var roll: Float = 0
    /// What the camera is pointed at, if it is pointed at anything; `roll` turns it about its
    /// own axis when it is not.
    public var target: SIMD3<Float>?
    public var fovDegrees: Float = 60
    public var near: Float = 0.1
    public var far: Float = 200

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

  /// three's Euler rotation in its default XYZ order, then a position: `RX · RY · RZ`.
  public func modelMatrix(position: SIMD3<Float>, rotation: SIMD3<Float>) -> simd_float4x4 {
    let (sx, cx) = (sin(rotation.x), cos(rotation.x))
    let (sy, cy) = (sin(rotation.y), cos(rotation.y))
    let (sz, cz) = (sin(rotation.z), cos(rotation.z))
    return simd_float4x4(
      SIMD4(cy * cz, cx * sz + cz * sx * sy, sx * sz - cx * cz * sy, 0),
      SIMD4(-cy * sz, cx * cz - sx * sy * sz, cz * sx + cx * sy * sz, 0),
      SIMD4(sy, -cy * sx, cx * cy, 0),
      SIMD4(position.x, position.y, position.z, 1))
  }

  /// How far back to sit so a subject fills the frame. A perspective camera's field of view
  /// is *vertical*, so the horizontal extent it can see is that times the aspect: narrow the
  /// window and width is the binding constraint, widen it and height is. Solving both and
  /// taking the larger fits either way round. The extents are the subject's size *on screen*,
  /// not in space — a ring system seen almost edge on is as wide as its radius and a fraction
  /// as tall. Never past the far plane: cropping shows part of something, and being beyond
  /// the far plane shows nothing at all.
  public func fitDistance(
    camera: Camera, aspect: Float, halfWidth: Float, halfHeight: Float, fill: Float = 0.9
  ) -> Float {
    let halfFov = tan(camera.fovDegrees * .pi / 360)
    let want = max(halfHeight / halfFov, halfWidth / (halfFov * aspect)) / fill
    let ceiling = camera.far - max(halfWidth, halfHeight) * 1.6
    return min(want, max(1, ceiling))
  }

  /// Onset detection: a fast envelope crossing a slow one, so something lands on hits rather
  /// than on loudness. A threshold on the level itself fires constantly through a loud
  /// passage and never through a quiet one.
  public struct Onset {
    public var rise: Float
    public var refractory: Float
    private var fast: Float = 0
    private var slow: Float = 0
    private var wait: Float = 0

    public init(rise: Float, refractory: Float) {
      self.rise = rise
      self.refractory = refractory
    }

    /// How hard it was hit, or zero.
    public mutating func detect(_ value: Float, dt: Float) -> Float {
      fast += (value - fast) * min(1, dt * 28)
      slow += (value - slow) * min(1, dt * 2.2)
      wait -= dt
      if wait > 0 || fast < 0.07 || fast < slow * rise { return 0 }
      wait = refractory
      return min(1, fast)
    }
  }

  /// A small deterministic generator, where a scene wants the web's own arbitrary sequence.
  public struct Roll {
    private var state: Double
    public init(seed: Double) { state = seed }
    public mutating func next() -> Float {
      state = (state * 9301 + 0.49297).truncatingRemainder(dividingBy: 1)
      return Float(state)
    }
  }

  /// The linear congruential generator the point clouds are laid out with.
  public struct Noise {
    private var seed: UInt64
    public init(seed: UInt64) { self.seed = seed }
    public mutating func next() -> Float {
      seed = (seed &* 1_664_525 &+ 1_013_904_223) % 4_294_967_296
      return Float(Double(seed) / 4_294_967_296)
    }
  }

  /// three's `BoxGeometry` at one segment a side: six quads with their outward normals.
  public enum Box {
    public static func build(width: Float, height: Float, depth: Float) -> (
      positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
    ) {
      let half = SIMD3(width, height, depth) / 2
      let faces: [(normal: SIMD3<Float>, across: SIMD3<Float>, up: SIMD3<Float>)] = [
        (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
        (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
        (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
        (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
        (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
      ]
      var positions: [SIMD3<Float>] = []
      var normals: [SIMD3<Float>] = []
      var indices: [UInt32] = []
      for face in faces {
        let centre = face.normal * half
        let across = face.across * half
        let up = face.up * half
        let first = UInt32(positions.count)
        for corner in [(-1, 1), (1, 1), (1, -1), (-1, -1)] as [(Float, Float)] {
          positions.append(centre + across * corner.0 + up * corner.1)
          normals.append(face.normal)
        }
        indices.append(contentsOf: [first, first + 1, first + 2, first, first + 2, first + 3])
      }
      return (positions, normals, indices)
    }
  }

  /// Symmetric smoothing, for a field of objects where an instant onset looks like a flash.
  public func glide(_ current: Float, toward target: Float, dt: Float, attack: Float, release: Float)
    -> Float
  {
    current + (target - current) * min(1, dt * (target > current ? attack : release))
  }

  /// three's `IcosahedronGeometry`: the solid's twenty faces subdivided `detail` times and
  /// pushed out to the sphere, in three's own order, and not indexed — as three leaves it.
  public enum Icosahedron {
    public static func build(radius: Float = 1, detail: Int = 0) -> [SIMD3<Float>] {
      let t = (1 + Float(5).squareRoot()) / 2
      let corners: [SIMD3<Float>] = [
        SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
        SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
        SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
      ]
      let faces = [
        0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
        1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
        3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
        4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
      ]
      var out: [SIMD3<Float>] = []
      let cols = detail + 1
      for face in stride(from: 0, to: faces.count, by: 3) {
        let a = corners[faces[face]]
        let b = corners[faces[face + 1]]
        let c = corners[faces[face + 2]]
        // A triangular lattice across the face, row by row toward `c`.
        var rowsOfPoints: [[SIMD3<Float>]] = []
        for i in 0...cols {
          let aj = simd_mix(a, c, SIMD3(repeating: Float(i) / Float(cols)))
          let bj = simd_mix(b, c, SIMD3(repeating: Float(i) / Float(cols)))
          let rows = cols - i
          var points: [SIMD3<Float>] = []
          for j in 0...rows {
            if j == 0 && i == cols {
              points.append(aj)
            } else {
              points.append(simd_mix(aj, bj, SIMD3(repeating: Float(j) / Float(rows))))
            }
          }
          rowsOfPoints.append(points)
        }
        for i in 0..<cols {
          for j in 0..<(2 * (cols - i) - 1) {
            let k = j / 2
            if j % 2 == 0 {
              out.append(contentsOf: [rowsOfPoints[i][k + 1], rowsOfPoints[i + 1][k], rowsOfPoints[i][k]])
            } else {
              out.append(
                contentsOf: [rowsOfPoints[i][k + 1], rowsOfPoints[i + 1][k + 1], rowsOfPoints[i + 1][k]])
            }
          }
        }
      }
      return out.map { simd_normalize($0) * radius }
    }
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
