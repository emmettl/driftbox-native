import DriftboxGPU
import Foundation

/// The chillwave scene: a sun with slatted bands, a wireframe floor running to the horizon,
/// haze. Everything that moves is driven by the audio rather than by a clock — bass drives
/// the sun and the ground swell, highs the grid's brightness — so the picture is a readout
/// of the mix and not a screensaver playing alongside it. A finger pulls the floor toward
/// it, in the vertex shader, so the grid lines stretch around the touch.
///
/// The web puts a `fog` in this scene and no material uses it: three only fogs a
/// `ShaderMaterial` that asks to be fogged, and neither of these does. So there is none here.
public final class SunsetScene: GPUGeometryScene {
  override public class var id: String { "sunset" }
  override public class var name: String { "Sunset" }
  override public class var accent: SIMD3<Float> { SIMD3(120, 255, 230) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0x0a, 0x04, 0x18) / 255 }

  var grid = SunsetGridUniforms()
  var sun = SunsetSunUniforms()
  var gridMesh: (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var sunMesh: (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int)!
  var gridPipeline: (any GPUPipeline)!
  var sunPipeline: (any GPUPipeline)!

  private func upload(_ built: (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])) throws
    -> (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int)
  {
    try (buffer(built.positions), buffer(built.uvs), indices(built.indices), built.indices.count)
  }

  override public func build() throws {
    grid.uSpread = 40
    grid.uTouch = SIMD2(0.5, 0.5)
    grid.uNear = SIMD3(0xff, 0x5f, 0xc8) / 255
    grid.uFar = SIMD3(0x4b, 0xe0, 0xff) / 255
    sun.uTop = SIMD3(0xff, 0xe6, 0x6d) / 255
    sun.uBottom = SIMD3(0xff, 0x2e, 0x93) / 255
    gridMesh = try upload(Plane.build(width: 140, height: 140, segments: SIMD2(120, 120)))
    sunMesh = try upload(Plane.build(width: 26, height: 26))
    // Both read a plane: its positions at location 0 and its uvs at 1.
    let plane: [GPUVertexLayout] = [.single(.float3, location: 0), .single(.float2, location: 1)]
    gridPipeline = try pipeline(.sunsetGrid, blend: .normal, vertexBuffers: plane)
    sunPipeline = try pipeline(.sunsetSun, blend: .normal, vertexBuffers: plane)
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    let warp = touchEnergy
    grid.uTime += dt
    grid.uBass = Analyser.ease(grid.uBass, toward: bass, dt: dt)
    grid.uHigh = Analyser.ease(grid.uHigh, toward: high, dt: dt)
    grid.uTouch = touchAt
    grid.uWarp = warp
    // How wide a slice of floor the camera sees, from its own field of view: a phone in
    // portrait sees a narrow one, a desktop window a wide one, and a fixed number is wrong
    // for both.
    grid.uSpread = 30 * aspect
    sun.uBass = Analyser.ease(sun.uBass, toward: bass, dt: dt)

    // The camera leans toward the finger, which is most of why the warp reads as depth
    // rather than as a texture effect.
    camera.position.y = 1.15 + bass * 0.22 + warp * 2.2
    camera.position.x += ((touchAt.x - 0.5) * 8.5 * warp - camera.position.x) * min(1, dt * 3)
    camera.target = SIMD3(0, 1.6, -30)

    let projection = camera.projectionMatrix(aspect: aspect)
    let view = camera.viewMatrix
    grid.projectionMatrix = projection
    grid.modelViewMatrix = view * Matrix4.model(position: SIMD3(0, -0.6, -30), rotationX: -.pi / 2)
    sun.projectionMatrix = projection
    sun.modelViewMatrix =
      view * Matrix4.model(position: SIMD3(0, 3.4, -46), scale: 1 + bass * 0.06 + warp * 0.04)
  }

  override public func encode(_ pass: any GPUPass) {
    // Furthest first, as three draws its transparent objects.
    draw(pass, pipeline: sunPipeline, mesh: sunMesh, uniforms: sun)
    draw(pass, pipeline: gridPipeline, mesh: gridMesh, uniforms: grid)
  }

  private func draw<Block: UniformBlock>(
    _ pass: any GPUPass, pipeline: any GPUPipeline,
    mesh: (positions: any GPUBuffer, uvs: any GPUBuffer, indices: any GPUBuffer, count: Int), uniforms: Block
  ) {
    pass.setPipeline(pipeline)
    pass.setUniforms(uniforms, binding: 0)
    pass.setVertexBuffer(mesh.positions, slot: 0)
    pass.setVertexBuffer(mesh.uvs, slot: 1)
    pass.drawIndexed(mesh.indices, count: mesh.count, instanceCount: 1)
  }
}
