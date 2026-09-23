/// A 4×4 matrix of floats, in columns, laid out as std140's `mat4` and Metal's `float4x4` are:
/// what a shader's matrix is filled from.
///
/// Apple's `simd_float4x4` is the same memory, but `simd` is Apple's alone, and the scenes are
/// meant to draw on Windows and Android too. So the arithmetic they need is here, in the column
/// convention three.js and `simd` both use: `a * b` applies `b` first.
public struct Matrix4: Equatable, Sendable {
  public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

  public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
    columns = (c0, c1, c2, c3)
  }

  public static let identity = Matrix4(
    SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

  public subscript(column: Int) -> SIMD4<Float> {
    get {
      switch column {
      case 0: columns.0
      case 1: columns.1
      case 2: columns.2
      default: columns.3
      }
    }
    set {
      switch column {
      case 0: columns.0 = newValue
      case 1: columns.1 = newValue
      case 2: columns.2 = newValue
      default: columns.3 = newValue
      }
    }
  }

  public var transpose: Matrix4 {
    let (a, b, c, d) = columns
    return Matrix4(
      SIMD4(a.x, b.x, c.x, d.x), SIMD4(a.y, b.y, c.y, d.y), SIMD4(a.z, b.z, c.z, d.z),
      SIMD4(a.w, b.w, c.w, d.w))
  }

  public static func * (m: Matrix4, v: SIMD4<Float>) -> SIMD4<Float> {
    m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
  }

  public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
    Matrix4(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
  }

  public static func == (a: Matrix4, b: Matrix4) -> Bool {
    a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
      && a.columns.3 == b.columns.3
  }
}
