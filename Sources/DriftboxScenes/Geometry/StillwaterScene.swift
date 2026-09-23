import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// Still water, for the darkwave one. Undertow is 82bpm with no snare anywhere, a rimshot,
/// and more reverb than anything else in the set — a record that is mostly the space around
/// the hits. Every other scene reads the mix as a LEVEL; this one reads EVENTS. A hit drops
/// a ring on a black water plane and the ring travels outward and dies; between hits nothing
/// moves but the drift. The reverb you can hear is the picture: something small happening in
/// something very big.
public final class StillwaterScene: GPUGeometryScene {
  override public class var id: String { "water" }
  override public class var name: String { "Stillwater" }
  override public class var accent: SIMD3<Float> { SIMD3(150, 220, 255) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x01, 0x04, 0x0c) / 255 }

  /// Points across the water, per side: dense enough that a ring reads as a ring rather
  /// than as a dotted line.
  static let side = 160
  static let extent: Float = 90
  /// Rings alive at once. Past about a dozen they overlap into noise anyway, and each one
  /// costs a loop iteration per vertex per frame. `stillwaterWater.glsl` has room for
  /// exactly this many.
  static let ripples = 12

  /// Holds the rings too, in `uRipples`: each is (x, z, age, strength); a dead one has
  /// strength 0 and contributes nothing, so expiry needs no branching in the shader.
  var water = StillwaterWaterUniforms()
  var haze = StillwaterHazeUniforms()
  var points: (any GPUBuffer)!
  var hazeMesh: (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var waterPipeline: (any GPUPipeline)!
  var hazePipeline: (any GPUPipeline)!
  var onBass = Onset(rise: 1.5, refractory: 0.16, rates: SIMD2(30, 2.5), floor: 0.06)
  var onHigh = Onset(rise: 1.7, refractory: 0.1, rates: SIMD2(30, 2.5), floor: 0.06)
  /// Deterministic placement, so the same track drops rings in the same places twice.
  var roll = Roll(seed: 0.371)
  var nextRing = 0
  var drift: Float = 0

  override public func build() throws {
    water.uPixel = 1
    water.uTouch = SIMD2(0.5, 0.5)
    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(Self.side * Self.side)
    // Deterministic scatter, so the surface is the same water every time it is opened.
    var noise = Noise(seed: 20857)
    func jitter() -> Float { noise.next() - 0.5 }
    let step = Self.extent / Float(Self.side - 1)
    for a in 0..<Self.side {
      for b in 0..<Self.side {
        let t = Float(b) / Float(Self.side - 1)
        // Biased away from the camera: the near rows are stretched across most of the screen
        // and the far ones crowded into the horizon, so an even grid would spend most of its
        // points where they cannot be told apart. Scattered off the lattice too — seen at
        // this angle a regular grid collapses into radial spokes converging on the vanishing
        // point, and water is not on a grid anyway.
        positions.append(
          SIMD3(
            (Float(a) / Float(Self.side - 1) - 0.5) * Self.extent + jitter() * step * 2.2, 0,
            -pow(t, 1.55) * Self.extent * 1.35 + 8 + jitter() * step * 2.6))
      }
    }
    points = try buffer(positions)
    let plane = Plane.build(width: 420, height: 60)
    hazeMesh = try (buffer(plane.positions), buffer(plane.uvs), indices(plane.indices), plane.indices.count)
    // A sprite per point rather than a Metal point: each point's position steps per instance.
    waterPipeline = try pipeline(
      .stillwaterWater, blend: .additive, vertexBuffers: [.single(.float3, location: 0, perInstance: true)])
    hazePipeline = try pipeline(
      .stillwaterHaze, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float2, location: 1)])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    water.uTime += dt
    // Not eased: the surface swell follows the low end loosely and the RINGS carry the
    // transients, so smoothing here costs nothing and keeps the water from jittering.
    water.uBass += (bass - water.uBass) * min(1, dt * 3)
    water.uHigh += (high - water.uHigh) * min(1, dt * 4)
    water.uWarp = touchEnergy
    water.uTouch = touchAt
    water.uPixel = input.pixelRatio

    for index in 0..<Self.ripples where water.uRipples[index].w > 0 {
      water.uRipples[index].z += dt
      // Dead once the ring has travelled past the far edge or faded out.
      if water.uRipples[index].z > 6 { water.uRipples[index].w = 0 }
    }
    func spawn(strength: Float, spread: Float) {
      // Kept in the near half: a ring dropped at the far edge is a bright smudge on the
      // horizon by the time it has expanded.
      water.uRipples[nextRing] = SIMD4(
        (roll.next() - 0.5) * Self.extent * spread * 0.7, -roll.next() * 42 * spread - 5, 0, strength)
      nextRing = (nextRing + 1) % Self.ripples
    }
    // Kicks land wide and heavy; the rimshot and the top end drop smaller rings nearer.
    let kick = onBass.detect(bass, dt: dt)
    if kick > 0 { spawn(strength: 1.5 + kick * 2.2, spread: 0.8) }
    let tick = onHigh.detect(high, dt: dt)
    if tick > 0 { spawn(strength: 0.5 + tick * 0.9, spread: 0.55) }

    // Low and slow. The camera sits just above the surface so the plane is seen almost edge
    // on, which is what makes it read as water going to a horizon rather than as a field of
    // dots seen from above. Pitched down enough to put the horizon in the upper third:
    // level with the surface is the truer water shot and leaves half the frame empty sky.
    drift += dt * 0.05
    let portrait = aspect < 0.85
    camera.position = SIMD3(
      sin(drift) * 2.2 + (touchAt.x - 0.5) * 3 * touchEnergy, (portrait ? 5.2 : 4.0) + water.uBass * 0.6, 12)
    camera.rotation = SIMD3(portrait ? -0.26 : -0.18, 0, sin(drift * 0.6) * 0.012)
    water.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    water.modelViewMatrix = camera.viewMatrix
    haze.projectionMatrix = water.projectionMatrix
    // Sat ON the waterline: the plane runs from y=0 upward, so the bright end of the
    // gradient is exactly where the water ends.
    haze.modelViewMatrix = camera.viewMatrix * Matrix4.model(position: SIMD3(0, 30, -118))
    haze.uBass = water.uBass
  }

  override public func encode(_ pass: any GPUPass) {
    // Haze first, as its render order asks.
    pass.setPipeline(hazePipeline)
    pass.setUniforms(haze, binding: 0)
    pass.setVertexBuffer(hazeMesh.positions, slot: 0)
    pass.setVertexBuffer(hazeMesh.uvs, slot: 1)
    pass.drawIndexed(hazeMesh.indices, count: hazeMesh.count, instanceCount: 1)

    pass.setPipeline(waterPipeline)
    pass.setUniforms(water, binding: 0)
    pass.setVertexBuffer(points, slot: 0)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.side * Self.side)
  }
}
