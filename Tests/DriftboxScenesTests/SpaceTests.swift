import DriftboxGPU
import DriftboxScenes
import Testing

/// The camera and the model matrices the geometry scenes share, on every platform: three's
/// conventions, which the web's scenes were composed in.
struct SpaceTests {
  /// Looking at something puts it in the middle of the screen, in front of the camera, and the
  /// ray through the middle of the screen runs straight at it.
  @Test func aCameraLooksAtItsTarget() {
    var camera = Camera()
    camera.position = SIMD3(4, 3, 10)
    camera.target = SIMD3(-1, 0.5, 0)
    let seen = camera.projectionMatrix(aspect: 16.0 / 9) * camera.viewMatrix * SIMD4(camera.target!, 1)
    #expect(abs(seen.x / seen.w) < 1e-5 && abs(seen.y / seen.w) < 1e-5)
    #expect(seen.z / seen.w > 0 && seen.z / seen.w < 1, "between the near and far planes, 0...1")
    let ray = camera.ray(through: SIMD2(0.5, 0.5), aspect: 16.0 / 9)
    let toward = (camera.target! - camera.position).normalized
    #expect((ray - toward).length < 1e-4)
  }

  /// The near plane lands at depth 0 and the far plane at 1, as the GPU layer's clip space has it.
  @Test func depthRunsFromNearToFar() {
    let camera = Camera()
    let projection = camera.projectionMatrix(aspect: 1)
    let near = projection * SIMD4(0, 0, -camera.near, 1)
    let far = projection * SIMD4(0, 0, -camera.far, 1)
    #expect(abs(near.z / near.w) < 1e-5)
    #expect(abs(far.z / far.w - 1) < 1e-5)
  }

  /// three's XYZ Euler order: a quarter turn about y takes x to -z, and one about x then takes
  /// that -z to y.
  @Test func eulerTurnsComposeAsThreesDo() {
    let turn = Matrix4.model(position: SIMD3(1, 2, 3), rotation: SIMD3(0, .pi / 2, 0))
    let moved = turn * SIMD4(1, 0, 0, 1)
    #expect((SIMD3(moved.x, moved.y, moved.z) - SIMD3(1, 2, 2)).length < 1e-5)
    let both = Matrix4.model(position: .zero, rotation: SIMD3(.pi / 2, .pi / 2, 0)) * SIMD4(1, 0, 0, 0)
    #expect((SIMD3(both.x, both.y, both.z) - SIMD3(0, 1, 0)).length < 1e-5)
  }
}
