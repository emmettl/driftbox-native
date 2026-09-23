import DriftboxGPU
import Foundation

/// Rings of Saturn. The first scene that is an OBJECT rather than a place: every other one
/// puts you inside something and this one puts a body in front of you and leaves you
/// outside it. The rings shimmer on the sixteenths, and the big hits punch holes in the
/// planet — a white flash, then a dark scar that outlives it by a long way, which is the
/// Shoemaker-Levy 9 detail worth stealing. Two point clouds and no lines: a gas giant drawn
/// in wireframe looks like a diagram of a gas giant.
public final class SaturnScene: GPUGeometryScene {
  override public class var id: String { "saturn" }
  override public class var name: String { "Saturn" }
  override public class var accent: SIMD3<Float> { SIMD3(150, 220, 255) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x03, 0x03, 0x0a) / 255 }

  /// Points on the planet, on a Fibonacci sphere so they are evenly spread rather than
  /// piled up at the poles the way a lat/long grid does.
  static let planetPoints = 14000
  static let planetRadius: Float = 9
  static let ringPoints = 26000
  static let ringInner: Float = 12
  static let ringOuter: Float = 22
  /// Impacts kept at once. Scars outlast flashes by a long way, so this holds more than
  /// there are hits in a bar. `saturnPlanet.glsl` has room for exactly this many.
  static let impacts = 10

  var planet = SaturnPlanetUniforms()
  var ring = SaturnRingUniforms()
  var planetPositions: (any GPUBuffer)!
  var ringRadii: (any GPUBuffer)!
  var ringPhases: (any GPUBuffer)!
  var ringGrit: (any GPUBuffer)!
  var planetPipeline: (any GPUPipeline)!
  var ringPipeline: (any GPUPipeline)!
  var onKick = Onset(rise: 1.55, refractory: 0.22)
  var roll = Roll(seed: 0.613)
  var nextImpact = 0
  var spin: Float = 0

  override public func build() throws {
    planet.uPixelRatio = 1
    ring.uPixelRatio = 1
    for index in 0..<Self.impacts { planet.uImpacts[index] = SIMD4(0, 1, 0, -1) }
    // The golden-angle spiral, nudged off itself: evenly spaced is exactly what produces a
    // moire, so the sphere would read as woven fabric rather than as cloud tops. A jitter of
    // a fraction of the spacing kills the interference without clumping the points.
    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(Self.planetPoints)
    let golden = Float.pi * (3 - Float(5).squareRoot())
    var noise = Noise(seed: 40503)
    func jitter(_ scale: Float) -> Float { (noise.next() - 0.5) * scale }
    for index in 0..<Self.planetPoints {
      let y = min(1, max(-1, 1 - Float(index) / Float(Self.planetPoints - 1) * 2 + jitter(0.02)))
      let radius = (max(0, 1 - y * y)).squareRoot()
      let theta = golden * Float(index) + jitter(0.06)
      positions.append(
        SIMD3(
          cos(theta) * radius * Self.planetRadius, y * Self.planetRadius,
          sin(theta) * radius * Self.planetRadius)
      )
    }
    planetPositions = try buffer(positions)

    // Gaps at fixed fractions of the way out: a solid annulus reads as a plate, and the
    // divisions are what make it read as rings, plural.
    var radii: [Float] = []
    var phases: [Float] = []
    var grit: [Float] = []
    var ringNoise = Noise(seed: 88172)
    let gaps: [(Float, Float)] = [(0.28, 0.33), (0.62, 0.66), (0.88, 0.91)]
    for _ in 0..<Self.ringPoints {
      var t = ringNoise.next()
      for (from, to) in gaps where t > from && t < to { t = t < (from + to) / 2 ? from : to }
      radii.append(Self.ringInner + t * (Self.ringOuter - Self.ringInner))
      phases.append(ringNoise.next() * .pi * 2)
      grit.append(ringNoise.next() * 2 - 1)
    }
    ringRadii = try buffer(radii)
    ringPhases = try buffer(phases)
    ringGrit = try buffer(grit)

    planetPipeline = try pipeline(
      .saturnPlanet, blend: .normal, vertexBuffers: [.single(.float3, location: 0, perInstance: true)])
    ringPipeline = try pipeline(
      .saturnRing, blend: .additive,
      vertexBuffers: (0..<3).map { .single(.float, location: $0, perInstance: true) })
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    planet.uTime += dt
    planet.uBass += (bass - planet.uBass) * min(1, dt * 4)
    planet.uHigh += (high - planet.uHigh) * min(1, dt * 5)
    planet.uPixelRatio = input.pixelRatio
    ring.uTime += dt
    ring.uBass = planet.uBass
    // Snapped up, eased down: the ring shimmer has to arrive with the hat, not swell into
    // it. Smoothing both ways turns a break into a wash.
    ring.uHat = high > ring.uHat ? high : ring.uHat + (high - ring.uHat) * min(1, dt * 7)
    ring.uWarp = touchEnergy
    ring.uPixelRatio = input.pixelRatio

    for index in 0..<Self.impacts where planet.uImpacts[index].w >= 0 {
      planet.uImpacts[index].w += dt
      // Retired once the scar has faded to nothing, not when the flash has.
      if planet.uImpacts[index].w > 26 { planet.uImpacts[index].w = -1 }
    }
    if onKick.detect(bass, dt: dt) > 0 {
      // Somewhere on the sphere, biased to the lit side so the flash is actually seen.
      let y = roll.next() * 1.3 - 0.55
      let a = roll.next() * .pi * 2
      let radius = (max(0.01, 1 - y * y)).squareRoot()
      planet.uImpacts[nextImpact] = SIMD4(cos(a) * radius - 0.35, y, sin(a) * radius + 0.5, 0)
      nextImpact = (nextImpact + 1) % Self.impacts
    }

    // The whole system turns, tilted, and a finger swings the camera round it and lifts the
    // ring plane toward edge-on.
    spin += dt * 0.06
    let system = Matrix4.model(
      position: .zero,
      rotation: SIMD3(0.42 - (touchAt.y - 0.5) * 0.7 * touchEnergy, spin, 0.16))
    // Framed against whichever edge is binding. Seen at this tilt the system is as wide as
    // the outer ring and roughly two thirds as tall.
    let orbit = (touchAt.x - 0.5) * 1.6 * touchEnergy
    let distance =
      fitDistance(camera: camera, aspect: aspect, halfWidth: Self.ringOuter, halfHeight: 15) - bass * 1.5
    camera.position = SIMD3(sin(orbit) * distance, 9 + bass * 0.8, cos(orbit) * distance)
    camera.target = .zero
    let modelView = camera.viewMatrix * system
    planet.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    planet.modelViewMatrix = modelView
    ring.projectionMatrix = planet.projectionMatrix
    ring.modelViewMatrix = modelView
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(planetPipeline)
    pass.setUniforms(planet, binding: 0)
    pass.setVertexBuffer(planetPositions, slot: 0)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.planetPoints)

    // Additive, so where the rings cross in front of the planet they brighten it rather than
    // punching a hole in it — which is what a field of ice does.
    pass.setPipeline(ringPipeline)
    pass.setUniforms(ring, binding: 0)
    pass.setVertexBuffer(ringRadii, slot: 0)
    pass.setVertexBuffer(ringPhases, slot: 1)
    pass.setVertexBuffer(ringGrit, slot: 2)
    pass.draw(vertexCount: Self.spriteVertices, instanceCount: Self.ringPoints)
  }
}
