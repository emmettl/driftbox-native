import DriftboxGPU
import Foundation

/// Cübik/Olympic: a white room made from the four inks on the single sleeve. The field is
/// one instanced buffer and one draw call, and its cubes do not simply jump as one loudness
/// meter — concentric rings are assigned to logarithmic frequency bands, while the low end
/// launches a second wave through the whole floor. A kick moves the landscape, a synth note
/// picks out one coloured ring, and a hat catches the top faces.
public final class CubikScene: GPUGeometryScene {
  override public class var id: String { "cubik" }
  override public class var name: String { "Cubik" }
  override public class var accent: SIMD3<Float> { SIMD3(40, 70, 130) / 255 }
  override public class var background: SIMD3<Float> { SIMD3(0xef, 0xed, 0xe5) / 255 }

  static let side = 27
  static let count = side * side
  static let spacing: Float = 0.64
  /// `cubik.glsl` has room for exactly this many bands.
  static let bandCount = 12
  static let targetZ: Float = -1.8
  static let orbitRadius = (7.8 * 7.8 + (12.8 - targetZ) * (12.8 - targetZ)).squareRoot()
  static let orbitStart = atan2(Float(7.8), 12.8 - targetZ)
  /// One revolution in roughly a minute and a half: movement you feel before you notice.
  static let orbitSpeed = Float.pi * 2 / 92

  var uniforms = CubikUniforms()
  var smoothed = [Float](repeating: 0, count: CubikScene.bandCount)
  var positions: (any GPUBuffer)!
  var normals: (any GPUBuffer)!
  /// The cube's indices. Not `indices`, which would shadow the base class's `indices(_:)`.
  var indexBuffer: (any GPUBuffer)!
  var grid: (any GPUBuffer)!
  var band: (any GPUBuffer)!
  var ink: (any GPUBuffer)!
  var indexCount = 0
  var pipelineState: (any GPUPipeline)!
  var orbit = CubikScene.orbitStart

  override public func build() throws {
    uniforms.uTouch = SIMD2(0.5, 0.5)
    let cube = Box.build(width: 0.48, height: 1, depth: 0.48)
    positions = try buffer(cube.positions)
    normals = try buffer(cube.normals)
    indexBuffer = try indices(cube.indices)
    indexCount = cube.indices.count

    var grid: [SIMD2<Float>] = []
    var bands: [Float] = []
    var inks: [Float] = []
    let half = Float(Self.side - 1) / 2
    for z in 0..<Self.side {
      for x in 0..<Self.side {
        let gx = Float(x) - half
        let gz = Float(z) - half
        grid.append(SIMD2(gx, gz))
        bands.append(Float(Int((gx * gx + gz * gz).squareRoot() * 0.9) % Self.bandCount))
        // Broad diagonal blocks of colour: ordered like printing ink, not confetti.
        inks.append(Float(((x + 3) / 5 + (z + 2) / 4) % 4))
      }
    }
    self.grid = try buffer(grid)
    band = try buffer(bands)
    ink = try buffer(inks)
    // The cube's corners step per vertex; where it stands, its band and its ink per instance.
    pipelineState = try pipeline(
      .cubik, blend: .none, depth: true,
      vertexBuffers: [
        .single(.float3, location: 0), .single(.float3, location: 1),
        .single(.float2, location: 2, perInstance: true), .single(.float, location: 3, perInstance: true),
        .single(.float, location: 4, perInstance: true),
      ])
  }

  override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
    let (bass, high) = input.wideLevels
    uniforms.uTime += dt * (0.64 + bass * 0.7)
    orbit = (orbit + dt * Self.orbitSpeed).truncatingRemainder(dividingBy: .pi * 2)
    uniforms.uBass = glide(uniforms.uBass, toward: bass, dt: dt, attack: 4, release: 2.6)
    uniforms.uHigh = glide(uniforms.uHigh, toward: high, dt: dt, attack: 6, release: 4)
    uniforms.uWarp = touchEnergy
    uniforms.uTouch = touchAt
    for lane in 0..<Self.bandCount {
      let raw = lane < input.bands.count ? input.bands[lane] : 0
      smoothed[lane] = glide(smoothed[lane], toward: raw, dt: dt, attack: 3.2, release: 2)
    }
    // Each band in the x of a vec4, as the block holds them.
    for lane in 0..<Self.bandCount { uniforms.uBands[lane] = SIMD4(smoothed[lane], 0, 0, 0) }

    // A slow lap around the board keeps the field changing even between interactions.
    // Horizontal touch nudges the angle rather than sliding the camera off its orbit, so the
    // gesture and the autonomous move compose instead of fighting one another.
    let angle = orbit + (touchAt.x - 0.5) * touchEnergy * 0.42
    let radius = Self.orbitRadius - uniforms.uBass * 1.1
    let want = SIMD3(
      sin(angle) * radius, 9.3 + (touchAt.y - 0.5) * touchEnergy * 2.4,
      Self.targetZ + cos(angle) * radius)
    camera.position += (want - camera.position) * min(1, dt * 2.2)
    camera.target = SIMD3(0, 0.6, Self.targetZ)
    camera.fovDegrees = 46
    camera.far = 80
    uniforms.projectionMatrix = camera.projectionMatrix(aspect: aspect)
    uniforms.modelViewMatrix = camera.viewMatrix
    uniforms.normalMatrix = camera.viewMatrix
  }

  override public func encode(_ pass: any GPUPass) {
    pass.setPipeline(pipelineState)
    pass.setUniforms(uniforms, binding: 0)
    pass.setVertexBuffer(positions, slot: 0)
    pass.setVertexBuffer(normals, slot: 1)
    pass.setVertexBuffer(grid, slot: 2)
    pass.setVertexBuffer(band, slot: 3)
    pass.setVertexBuffer(ink, slot: 4)
    pass.drawIndexed(indexBuffer, count: indexCount, instanceCount: Self.count)
  }
}
