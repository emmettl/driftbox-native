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

  /// The matrix that undoes this one, by cofactors; a singular matrix has none, and gives its
  /// cofactors over zero. `aij` is column i, row j, as in three's and gl-matrix's own.
  public var inverse: Matrix4 {
    let (c0, c1, c2, c3) = columns
    let (a00, a01, a02, a03) = (c0.x, c0.y, c0.z, c0.w)
    let (a10, a11, a12, a13) = (c1.x, c1.y, c1.z, c1.w)
    let (a20, a21, a22, a23) = (c2.x, c2.y, c2.z, c2.w)
    let (a30, a31, a32, a33) = (c3.x, c3.y, c3.z, c3.w)
    let b00 = a00 * a11 - a01 * a10
    let b01 = a00 * a12 - a02 * a10
    let b02 = a00 * a13 - a03 * a10
    let b03 = a01 * a12 - a02 * a11
    let b04 = a01 * a13 - a03 * a11
    let b05 = a02 * a13 - a03 * a12
    let b06 = a20 * a31 - a21 * a30
    let b07 = a20 * a32 - a22 * a30
    let b08 = a20 * a33 - a23 * a30
    let b09 = a21 * a32 - a22 * a31
    let b10 = a21 * a33 - a23 * a31
    let b11 = a22 * a33 - a23 * a32
    let determinant = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06
    let d = 1 / determinant
    return Matrix4(
      SIMD4(
        a11 * b11 - a12 * b10 + a13 * b09, a02 * b10 - a01 * b11 - a03 * b09,
        a31 * b05 - a32 * b04 + a33 * b03, a22 * b04 - a21 * b05 - a23 * b03) * d,
      SIMD4(
        a12 * b08 - a10 * b11 - a13 * b07, a00 * b11 - a02 * b08 + a03 * b07,
        a32 * b02 - a30 * b05 - a33 * b01, a20 * b05 - a22 * b02 + a23 * b01) * d,
      SIMD4(
        a10 * b10 - a11 * b08 + a13 * b06, a01 * b08 - a00 * b10 - a03 * b06,
        a30 * b04 - a31 * b02 + a33 * b00, a21 * b02 - a20 * b04 - a23 * b00) * d,
      SIMD4(
        a11 * b07 - a10 * b09 - a12 * b06, a00 * b09 - a01 * b07 + a02 * b06,
        a31 * b01 - a30 * b03 - a32 * b00, a20 * b03 - a21 * b01 + a22 * b00) * d)
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
