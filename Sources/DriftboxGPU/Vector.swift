/// The vector arithmetic the scenes need for their geometry and cameras, on the standard library's
/// own SIMD types. Apple's `simd` has all of it, but only on Apple's platforms; these are members
/// rather than free functions so that they never compete with `simd`'s where both are imported.
extension SIMD3 where Scalar == Float {
  public func dot(_ other: Self) -> Float { (self * other).sum() }

  public func cross(_ other: Self) -> Self {
    Self(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
  }

  public var length: Float { dot(self).squareRoot() }
  public var lengthSquared: Float { dot(self) }
  /// The same direction at length one; the zero vector has none, and gives NaNs as `simd` does.
  public var normalized: Self { self / length }

  public func distance(to other: Self) -> Float { (self - other).length }
  /// Where `t` of the way to `other` is: `simd_mix`, and GLSL's `mix`.
  public func mix(_ other: Self, _ t: Float) -> Self { self + (other - self) * t }
}

extension SIMD2 where Scalar == Float {
  public func dot(_ other: Self) -> Float { (self * other).sum() }
  public var length: Float { dot(self).squareRoot() }
  public var lengthSquared: Float { dot(self) }
  public var normalized: Self { self / length }
  public func distance(to other: Self) -> Float { (self - other).length }
  public func mix(_ other: Self, _ t: Float) -> Self { self + (other - self) * t }
}
