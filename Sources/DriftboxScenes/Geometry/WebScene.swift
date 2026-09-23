import DriftboxGPU
import Foundation

/// The web. Tempest 2000. Not another tunnel: this is a well that narrows to a point and
/// does not move at all — you look into it, and things travel up the lanes toward you, which
/// is why it is built from spokes rather than ribs. Sixteen lanes, sixteen logarithmic
/// bands, so a kick lights one lane and a hat another and the web reads as the *shape* of
/// the mix rather than as its loudness. A finger is a black hole and the web falls into it.
public final class WebScene: GPUGeometryScene {
  override public class var id: String { "web" }
  override public class var name: String { "Web" }
  override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  override public class var background: SIMD3<Float> { SIMD3(0x03, 0x00, 0x0a) / 255 }

  /// Tempest's own count for a circular web, and conveniently the number of steps in a bar.
  /// `web.glsl` has room for exactly this many bands.
  static let lanes = 16
  /// Rings from the rim down to the throat.
  static let rings = 14
  static let rim: Float = 13

  var uniforms = WebUniforms()
  var eased = [Float](repeating: 0, count: WebScene.lanes)
  var positions: (any GPUBuffer)!
  var lanes: (any GPUBuffer)!
  var ringsBuffer: (any GPUBuffer)!
  var count = 0
  var pipelineState: (any GPUPipeline)!

  override public func build() throws {
    uniforms.uEye = SIMD3(0, 0, 15)
    uniforms.uRay = SIMD3(0, 0, -1)
    var positions: [SIMD3<Float>] = []
    var laneOf: [Float] = []
    var ringOf: [Float] = []
    // `ring` runs 0 at the throat to 1 at the rim, and drives both radius and depth — a well
    // rather than a tube, so it narrows away from you instead of running parallel.
    func at(lane: Int, ring: Int) -> SIMD3<Float> {
      let a = Float(lane) / Float(Self.lanes) * .pi * 2
      let t = Float(ring) / Float(Self.rings - 1)
      let radius = Self.rim * (0.06 + 0.94 * t * t)
      return SIMD3(cos(a) * radius, sin(a) * radius, -34 * (1 - t) * (1 - t))
    }
    func push(lane: Int, ring: Int) {
      positions.append(at(lane: lane, ring: ring))
      laneOf.append(Float(lane % Self.lanes))
      ringOf.append(Float(ring) / Float(Self.rings - 1))
    }
    // The spokes. These are what make it a web rather than a tunnel.
    for lane in 0..<Self.lanes {
      for ring in 0..<(Self.rings - 1) {
        push(lane: lane, ring: ring)
        push(lane: lane, ring: ring + 1)
      }
    }
    // And a ring at each depth, closing the lanes into cells.
    for ring in 0..<Self.rings {
      for lane in 0..<Self.lanes {
        push(lane: lane, ring: ring)
        push(lane: lane + 1, ring: ring)
      }
    }
    self.positions = try buffer(positions)
    self.lanes = try buffer(laneOf)
    ringsBuffer = try buffer(ringOf)
    count = positions.count
    pipelineState = try pipeline(
      .web, primitive: .lines, blend: .additive,
      vertexBuffers: [
        .single(.float3, location: 0), .single(.float, location: 1), .single(.float, location: 2),
      ])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    uniforms.uTime += dt
    uniforms.uBass = Analyser.ease(uniforms.uBass, toward: bass, dt: dt, fall: 5)
    uniforms.uHigh = Analyser.ease(uniforms.uHigh, toward: high, dt: dt, fall: 6)
    uniforms.uWarp = touchEnergy
    // Eased per lane, so a hit blooms and falls away instead of strobing on one frame.
    let bands = input.bands
    for lane in 0..<Self.lanes {
      eased[lane] = Analyser.ease(
        eased[lane], toward: lane < bands.count ? bands[lane] : 0, dt: dt, fall: 4.5)
    }
    // Each band in the x of a vec4, as the block holds them.
    for lane in 0..<Self.lanes { uniforms.uBands[lane] = SIMD4(eased[lane], 0, 0, 0) }

    // Further back on a tall screen: the web is as wide as it is anything, and a portrait
    // phone at the desktop distance puts you so far inside it that the rim is off the edges.
    let portrait = aspect < 0.85
    camera.position = SIMD3(0, 0, (portrait ? 23 : 15) - bass * 1.6)
    camera.roll += dt * 0.05
    uniforms.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    uniforms.modelViewMatrix = camera.viewMatrix
    // The eye ray through the fingertip, from the camera itself, so it holds at any fov,
    // aspect or distance — and this camera also rolls.
    uniforms.uEye = camera.position
    uniforms.uRay = camera.ray(through: touchAt, aspect: aspect)
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(pipelineState)
    pass.setUniforms(uniforms, binding: 0)
    pass.setVertexBuffer(positions, slot: 0)
    pass.setVertexBuffer(lanes, slot: 1)
    pass.setVertexBuffer(ringsBuffer, slot: 2)
    pass.draw(vertexCount: count)
  }
}
