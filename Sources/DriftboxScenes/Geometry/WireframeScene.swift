import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// Flying down a wireframe corridor. The Rez one. Hard thin lines, no fill, cyan and
/// magenta, everything snapping on the beat: sixty-four hexagonal ribs and the rails joining
/// them, in one line list moved entirely in the vertex shader, surging on every kick.
public final class WireframeScene: GPUGeometryScene {
  override public class var id: String { "wireframe" }
  override public class var name: String { "Wireframe" }
  override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
  override public class var background: SIMD3<Float> { SIMD3(0x03, 0x02, 0x0a) / 255 }

  static let depth: Float = 120
  static let ribs = 64
  static let sides = 6

  var uniforms = WireframeUniforms()
  var positions: (any GPUBuffer)!
  var depths: (any GPUBuffer)!
  var count = 0
  var lines: (any GPUPipeline)!
  var travelled: Float = 0

  override public func build() throws {
    uniforms.uTouch = SIMD2(0.5, 0.5)
    uniforms.uNear = SIMD3(0x5f, 0xf0, 0xd0) / 255
    uniforms.uFar = SIMD3(0xc4, 0x3b, 0xff) / 255
    var positions: [SIMD3<Float>] = []
    var depths: [Float] = []
    let radius: Float = 9.5
    for index in 0..<Self.ribs {
      let z = Float(index) / Float(Self.ribs) * Self.depth
      for side in 0..<Self.sides {
        for step in [side, side + 1] {
          let a = Float(step) / Float(Self.sides) * .pi * 2
          positions.append(SIMD3(cos(a) * radius, sin(a) * radius, 0))
          depths.append(z)
        }
      }
    }
    // The rails: long lines down the corridor at each corner, which is what sells the speed.
    for side in 0..<Self.sides {
      let a = Float(side) / Float(Self.sides) * .pi * 2
      let corner = SIMD3(cos(a) * radius, sin(a) * radius, 0)
      for index in 0..<(Self.ribs - 1) {
        positions.append(corner)
        positions.append(corner)
        depths.append(Float(index) / Float(Self.ribs) * Self.depth)
        depths.append(Float(index + 1) / Float(Self.ribs) * Self.depth)
      }
    }
    self.positions = try buffer(positions)
    self.depths = try buffer(depths)
    count = positions.count
    lines = try pipeline(
      .wireframe, primitive: .lines, blend: .additive,
      vertexBuffers: [.single(.float3, location: 0), .single(.float, location: 1)])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    let warp = touchEnergy
    // Speed follows the low end, so the corridor surges on every kick.
    travelled += dt * (20 + bass * 34)
    uniforms.uTime = travelled
    uniforms.uBass = Analyser.ease(uniforms.uBass, toward: bass, dt: dt, fall: 4.5)
    uniforms.uHigh = Analyser.ease(uniforms.uHigh, toward: high, dt: dt, fall: 6)
    uniforms.uWarp = warp
    uniforms.uTouch = touchAt
    // The camera rolls slightly with the finger; small, because a corridor that rolls too
    // far stops reading as a corridor.
    camera.roll += ((touchAt.x - 0.5) * -0.5 * warp - camera.roll) * min(1, dt * 2.5)
    camera.position.x += ((touchAt.x - 0.5) * 2.4 * warp - camera.position.x) * min(1, dt * 3)
    camera.position.y += ((touchAt.y - 0.5) * 1.8 * warp - camera.position.y) * min(1, dt * 3)
    camera.position.z = 3 - bass * 1.2
    uniforms.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    uniforms.modelViewMatrix = camera.viewMatrix
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(lines)
    pass.setUniforms(uniforms, binding: 0)
    pass.setVertexBuffer(positions, slot: 0)
    pass.setVertexBuffer(depths, slot: 1)
    pass.draw(vertexCount: count)
  }
}
