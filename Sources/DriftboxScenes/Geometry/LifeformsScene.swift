import DriftboxGPU
import Foundation

/// Pulsing spheres, drifting in deep space — the ISDN-era Future Sound of London videos:
/// organic bodies breathing slowly, wireframe over translucent, nothing quite still and
/// nothing quite symmetrical. The surfaces are NOT spheres: every vertex is pushed in and
/// out by layered noise, so the silhouette is always changing and never repeats exactly.
/// Bass inflates, highs make the surface twitch, a finger drags them toward it.
public final class LifeformsScene: GPUGeometryScene {
  override public class var id: String { "lifeforms" }
  override public class var name: String { "Lifeforms" }
  override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  override public class var background: SIMD3<Float> { SIMD3(0x04, 0x03, 0x0c) / 255 }

  /// Where the bodies sit, how big, and what colour. Hand-placed rather than random: a
  /// random cluster looks like a mistake, and the depth ordering is what gives the scene
  /// somewhere to be.
  struct Body {
    var position: SIMD3<Float>
    var size: Float
    var seed: Float
    var inner: SIMD3<Float>
    var rim: SIMD3<Float>
  }

  static func colour(_ hex: UInt32) -> SIMD3<Float> {
    SIMD3(Float((hex >> 16) & 0xff), Float((hex >> 8) & 0xff), Float(hex & 0xff)) / 255
  }

  static let bodies: [Body] = [
    Body(position: SIMD3(0, 0.2, -4), size: 1.5, seed: 0, inner: colour(0x2a0f4d), rim: colour(0xff5fc8)),
    Body(
      position: SIMD3(-3.4, 1.1, -8), size: 1.1, seed: 3.7, inner: colour(0x08303d), rim: colour(0x4be0ff)),
    Body(
      position: SIMD3(3.6, -0.6, -9), size: 1.35, seed: 8.1, inner: colour(0x3d1030), rim: colour(0xffb02e)),
    Body(
      position: SIMD3(-1.6, -1.8, -13), size: 2.1, seed: 12.4, inner: colour(0x101a45),
      rim: colour(0x8a6bff)),
    Body(
      position: SIMD3(4.4, 2.3, -16), size: 1.7, seed: 17.9, inner: colour(0x2c0a2a), rim: colour(0xff2e93)),
    Body(
      position: SIMD3(-5.2, -0.4, -19), size: 2.4, seed: 21.3, inner: colour(0x062c33),
      rim: colour(0x5ff0d0)),
    Body(
      position: SIMD3(1.2, 3.1, -23), size: 2, seed: 26.8, inner: colour(0x1a0b3a), rim: colour(0xc46bff)),
  ]

  /// One block per body, each set before that body is drawn.
  var uniforms = [LifeformsUniforms]()
  var spin = [SIMD2<Float>](repeating: .zero, count: LifeformsScene.bodies.count)
  var positions: (any GPUBuffer)!
  var count = 0
  var pipelineState: (any GPUPipeline)!
  var drift: Float = 0

  override public func build() throws {
    // Detail 5: enough that the noise reads as a surface rather than as facets, and cheap
    // enough to run seven of.
    let mesh = Icosahedron.build(radius: 1, detail: 5)
    positions = try buffer(mesh)
    count = mesh.count
    uniforms = Self.bodies.map { body in
      var one = LifeformsUniforms()
      one.uTime = body.seed
      one.uSeed = body.seed
      one.uInner = body.inner
      one.uRim = body.rim
      return one
    }
    pipelineState = try pipeline(
      .lifeforms, blend: .additive, vertexBuffers: [.single(.float3, location: 0)])
  }

  /// How far apart the bodies sit, given the shape of the screen. The cluster is hand-placed
  /// about twice as wide as it is tall, which frames well in landscape and badly on a phone;
  /// squeezing it horizontally and stretching it vertically is cheaper than solving it with
  /// camera distance alone.
  static func spread(aspect: Float) -> SIMD2<Float> {
    aspect >= 0.85 ? SIMD2(1, 1) : SIMD2(0.6, 2.5)
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    let warp = touchEnergy
    let spread = Self.spread(aspect: aspect)
    drift += dt * 0.08

    // A slow wander, so it never settles into a still frame, plus a lean toward the finger
    // and a push back on the kick.
    camera.position.x +=
      (sin(drift) * 1.4 + (touchAt.x - 0.5) * 5 * warp - camera.position.x) * min(1, dt * 1.6)
    camera.position.y +=
      (cos(drift * 0.7) * 0.9 + (touchAt.y - 0.5) * 3 * warp - camera.position.y) * min(1, dt * 1.6)
    // Pull back on a tall screen: the same composition that works in landscape falls apart
    // turned ninety degrees.
    camera.position.z = (aspect < 0.85 ? 7.2 : 5.5) - bass * 0.6
    camera.target = SIMD3(0, 0.4, -12)
    let projection = camera.projectionMatrix(aspect: aspect)
    let view = camera.viewMatrix

    for index in uniforms.indices {
      let body = Self.bodies[index]
      uniforms[index].uTime += dt
      uniforms[index].uBass = Analyser.ease(uniforms[index].uBass, toward: bass, dt: dt, fall: 2.4)
      uniforms[index].uHigh = Analyser.ease(uniforms[index].uHigh, toward: high, dt: dt, fall: 5)
      uniforms[index].uWarp = warp
      // The finger, put into the scene at this body's depth so the pull is toward a point in
      // space rather than toward the camera plane; relative to the body, since the shader
      // works in object space.
      uniforms[index].uPull = SIMD3(
        (touchAt.x - 0.5) * 9, (touchAt.y - 0.5) * 7, -body.position.z * 0.15)
      // Everything turns, slowly, at its own rate and on its own axis: uniform rotation would
      // make seven bodies look like one object.
      spin[index].y += dt * (0.05 + body.seed * 0.004)
      spin[index].x += dt * 0.021
      let place = SIMD3(
        body.position.x * spread.x,
        body.position.y * spread.y + sin(uniforms[index].uTime * 0.31 + body.seed) * 0.35,
        body.position.z)
      let scale = body.size * (1 + bass * 0.1)
      let model =
        Matrix4.model(position: place, rotation: SIMD3(spin[index].x, spin[index].y, 0))
        * Matrix4(
          SIMD4(scale, 0, 0, 0), SIMD4(0, scale, 0, 0), SIMD4(0, 0, scale, 0), SIMD4(0, 0, 0, 1))
      uniforms[index].projectionMatrix = projection
      uniforms[index].modelViewMatrix = view * model
      // For a rotation and a uniform scale the inverse transpose is the rotation itself, and
      // the shader normalises what comes out.
      uniforms[index].normalMatrix = view * model
    }
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(pipelineState)
    pass.setVertexBuffer(positions, slot: 0)
    for index in uniforms.indices {
      pass.setUniforms(uniforms[index], binding: 0)
      pass.draw(vertexCount: count)
    }
  }
}
