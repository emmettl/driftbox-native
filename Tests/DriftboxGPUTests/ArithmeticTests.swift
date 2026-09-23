import DriftboxGPU
import Testing

/// The arithmetic the scenes' cameras and geometry use, which Apple's `simd` did for them before
/// they drew on other platforms: held to what `simd` gives for the same inputs.
struct ArithmeticTests {
  static func close(_ a: Matrix4, _ b: Matrix4, within tolerance: Float = 1e-5) -> Bool {
    (0..<4).allSatisfy { column in
      let difference = a[column] - b[column]
      return max(difference.max(), -difference.min()) <= tolerance
    }
  }

  @Test func aMatrixTimesItsInverseIsTheIdentity() {
    // Turned, scaled unevenly, moved, and with a w row of its own, so every cofactor is used. Not
    // a camera's projection: one with a near plane of 0.1 and a far of 200 is ill-conditioned
    // enough that single precision cannot round-trip it this closely, which `Camera.ray` does
    // not need (see `SpaceTests`).
    let matrix = Matrix4(
      SIMD4(1.6, 0.72, -0.96, 0.1), SIMD4(0, 0.8, 0.6, -0.2), SIMD4(0.3, -0.24, 0.32, 0.05),
      SIMD4(-1, -2.5, -9, 1))
    #expect(Self.close(matrix * matrix.inverse, .identity))
    #expect(Self.close(matrix.inverse * matrix, .identity))
    #expect(Self.close(Matrix4.identity.inverse, .identity, within: 0))
  }

  @Test func vectorsDoWhatSimdDoes() {
    let a = SIMD3<Float>(1, 2, 3)
    let b = SIMD3<Float>(-2, 0.5, 4)
    #expect(a.dot(b) == 11)
    #expect(a.cross(b) == SIMD3(6.5, -10, 4.5))
    #expect(SIMD3<Float>(3, 4, 0).length == 5)
    #expect(SIMD3<Float>(3, 4, 0).lengthSquared == 25)
    #expect(SIMD3<Float>(0, 0, 2).normalized == SIMD3(0, 0, 1))
    #expect(a.distance(to: a + SIMD3(0, 3, 4)) == 5)
    #expect(a.mix(b, 0.5) == SIMD3(-0.5, 1.25, 3.5))
    #expect(SIMD2<Float>(6, 8).normalized == SIMD2(0.6, 0.8))
  }
}
