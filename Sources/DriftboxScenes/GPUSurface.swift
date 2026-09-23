import DriftboxGPU
import Foundation

/// The web's "material studies" on the GPU layer: a scene that is one fragment shader over the
/// whole screen, fed the same handful of numbers, and sometimes a layer of instanced cards over it.
/// The Metal `SurfaceScene`, moved across: the shaders are its MSL back in GLSL, which is nearer
/// still to the web's, and this keeps the clocks, eases the bands, warps to the touch and counts
/// hits exactly as that does. A subclass names itself and its programs, and lays out its cards.
///
/// The uniforms every program reads are `SurfaceUniforms`, in `shaders/DriftboxScenes/surface.glsl`.
open class GPUSurfaceScene: GPUScene {
  open class var id: String { fatalError("a surface scene names itself") }
  open class var name: String { fatalError("a surface scene names itself") }
  open class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  /// The surface: a fragment over `fullscreen.vert`.
  open class var program: ShaderProgram { fatalError("a surface scene names its shader") }
  /// A second layer of instanced quads over the surface — the web's `instancedMesh` of
  /// `planeGeometry` cards — drawn with this program, if the scene has one. Its vertex shader reads
  /// each card's matrix as four columns, `aInstance0...3`.
  open class var cardProgram: ShaderProgram? { nil }
  /// How many cards there are, always; the buffer they are written to is made to fit.
  open class var cardCount: Int { 0 }
  /// The cards' matrices, as the web composes them: translation (x, y, seed), a turn about z, a
  /// scale. Asked for every frame; a scene that lays them out by aspect can.
  open func cards(aspect: Float) -> [Matrix4] { [] }

  private let pipeline: any GPUPipeline
  private let cardPipeline: (any GPUPipeline)?
  private let cardBuffer: (any GPUBuffer)?
  var uniforms = SurfaceUniforms()
  var lastTime: Double?
  /// The finger's last known place, kept after it lifts so the warp eases out where it was.
  private var touchAt = SIMD2<Float>(0.5, 0.5)
  private var touchEnergy: Float = 0
  /// The hit detector: the mid band's recent level, when it last fired, and the slot to fill.
  private var hitPrevious: Float = 0
  private var hitLast: Float = -1
  private var hitNext = 0

  public required init(device: any GPUDevice) throws {
    pipeline = try device.makePipeline(GPUPipelineDescriptor(program: Self.program))
    if let program = Self.cardProgram, Self.cardCount > 0 {
      let columns = (0..<4).map { column in
        GPUVertexLayout.Attribute(location: column, format: .float4, offset: column * 16)
      }
      // three's normal blending: straight alpha over what is there.
      cardPipeline = try device.makePipeline(
        GPUPipelineDescriptor(
          program: program, blend: .normal,
          vertexBuffers: [GPUVertexLayout(stride: 64, perInstance: true, attributes: columns)]))
      let empty = [Matrix4](repeating: .identity, count: Self.cardCount)
      cardBuffer = try empty.withUnsafeBytes { try device.makeBuffer($0, kind: .vertex) }
    } else {
      cardPipeline = nil
      cardBuffer = nil
    }
    uniforms.uSize = SIMD2(1, 1)
    uniforms.uTouch = SIMD3(0.5, 0.5, 0)
    for slot in 0..<8 { uniforms.uHits[slot] = SIMD4(-100, 0, 0, 0) }
  }

  public func draw(_ input: SceneInput, into target: any GPUTarget, on device: any GPUDevice) {
    advance(input, size: SIMD2(target.width, target.height))
    let instances = cards(aspect: uniforms.uSize.x / uniforms.uSize.y)
    precondition(instances.count <= Self.cardCount, "\(Self.id) has more cards than it said")
    if let cardBuffer, !instances.isEmpty {
      // A frame is drawn whether or not its cards could be written; they are last frame's if not.
      try? instances.withUnsafeBytes { try cardBuffer.update($0) }
    }
    device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
      pass.setPipeline(pipeline)
      pass.setUniforms(uniforms, binding: 0)
      pass.draw(vertexCount: 3)
      if let cardPipeline, let cardBuffer, !instances.isEmpty {
        pass.setPipeline(cardPipeline)
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(cardBuffer, slot: 0)
        pass.draw(vertexCount: 6, instanceCount: instances.count)
      }
    }
  }

  /// three's `Matrix4.compose`: a translation, a turn about z, a scale.
  public static func compose(x: Float, y: Float, z: Float, angle: Float, scale: SIMD2<Float>)
    -> Matrix4
  {
    let c = cos(angle)
    let s = sin(angle)
    return Matrix4(
      SIMD4(c * scale.x, s * scale.x, 0, 0),
      SIMD4(-s * scale.y, c * scale.y, 0, 0),
      SIMD4(0, 0, 1, 0),
      SIMD4(x, y, z, 1))
  }

  /// One frame of the web's `useFrame`: the clocks run, the bands ease, the touch warps.
  func advance(_ input: SceneInput, size: SIMD2<Int>) {
    let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
    lastTime = input.time
    uniforms.uSize = SIMD2(Float(size.x), Float(size.y))
    uniforms.uTime += dt
    if input.running {
      uniforms.uTravel += dt
      uniforms.uBeat += dt * Float(input.bpm) / 60
      uniforms.uScoreBeat = input.scoreBeat.map { Float($0) } ?? uniforms.uBeat
    }
    uniforms.uBass = Analyser.ease(uniforms.uBass, toward: input.levels.bass, dt: dt)
    uniforms.uMid = Analyser.ease(uniforms.uMid, toward: input.levels.mid, dt: dt)
    uniforms.uHigh = Analyser.ease(uniforms.uHigh, toward: input.levels.high, dt: dt, fall: 6)

    // The warp eases in under a finger and out after it lifts, so nothing snaps.
    if let touch = input.touch { touchAt = touch }
    let down: Float = input.touch == nil ? 0 : 1
    let rate: Float = input.touch == nil ? 1.8 : 6
    touchEnergy += (down - touchEnergy) * min(1, min(dt, 0.05) * rate)
    if input.touch == nil, touchEnergy < 0.001 { touchEnergy = 0 }
    uniforms.uTouch = SIMD3(touchAt.x, touchAt.y, touchEnergy)

    // A rise in the mids is a hit, at most seven a second; the shader is told when and how hard.
    let mid = input.levels.mid
    if input.running, mid - hitPrevious > 0.025, uniforms.uTime - hitLast > 0.14 {
      uniforms.uHits[hitNext] = SIMD4(uniforms.uTime, min(1, mid * 2), 0, 0)
      hitNext = (hitNext + 1) % 8
      hitLast = uniforms.uTime
    }
    hitPrevious += (mid - hitPrevious) * min(1, dt * 12)
  }
}
