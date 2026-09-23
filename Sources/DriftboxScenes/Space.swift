import DriftboxGPU
import Foundation

/// three's perspective camera, as far as the scenes use it: a position, a roll about z, and
/// a projection. The matrices are what a three vertex shader calls `projectionMatrix` and
/// `modelViewMatrix` (with the model at the origin), except that depth lands in 0...1, as the GPU
/// layer's clip space has it, rather than GL's -1...1.
/// Its defaults are the web canvas's own — `fov: 60, position: [0, 1.15, 6], near: 0.1,
/// far: 200` — because a scene that never sets one of them is relying on it.
public struct Camera {
  public var position = SIMD3<Float>(0, 1.15, 6)
  public var roll: Float = 0
  /// What the camera is pointed at, if it is pointed at anything; `roll` turns it about its
  /// own axis when it is not.
  public var target: SIMD3<Float>?
  /// Or its Euler angles, for a scene that aims the camera rather than pointing it at
  /// something. Takes precedence over both of the above.
  public var rotation: SIMD3<Float>?
  public var fovDegrees: Float = 60
  public var near: Float = 0.1
  public var far: Float = 200

  public init() {}

  public func projectionMatrix(aspect: Float) -> Matrix4 {
    let f = 1 / tan(fovDegrees * .pi / 360)
    let range = far - near
    return Matrix4(
      SIMD4(f / aspect, 0, 0, 0),
      SIMD4(0, f, 0, 0),
      SIMD4(0, 0, -far / range, -1),
      SIMD4(0, 0, -far * near / range, 0))
  }

  public var viewMatrix: Matrix4 {
    let translate = Matrix4(
      SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
      SIMD4(-position.x, -position.y, -position.z, 1))
    if let rotation {
      // The camera's own transform is `T · R`, so what the world is seen through is its
      // inverse — and for an orthonormal rotation that is its transpose.
      let turn = Matrix4.model(position: .zero, rotation: rotation).transpose
      return turn * translate
    }
    guard let target else {
      let c = cos(-roll)
      let s = sin(-roll)
      let rotate = Matrix4(
        SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
      return rotate * translate
    }
    // three's `lookAt`: z away from what is looked at, y up, as the camera's own axes.
    let back = (position - target).normalized
    let right = SIMD3<Float>(0, 1, 0).cross(back).normalized
    let up = back.cross(right)
    let rotate = Matrix4(
      SIMD4(right.x, up.x, back.x, 0), SIMD4(right.y, up.y, back.y, 0),
      SIMD4(right.z, up.z, back.z, 0), SIMD4(0, 0, 0, 1))
    return rotate * translate
  }

  /// three's `unproject`, as the scenes use it: the direction from the eye through a point
  /// on the screen, 0...1 from the bottom left. Any depth on that line gives the same
  /// direction, so the near plane's own convention does not matter here.
  public func ray(through point: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
    let ndc = SIMD4<Float>(point.x * 2 - 1, point.y * 2 - 1, 0.5, 1)
    let world = (projectionMatrix(aspect: aspect) * viewMatrix).inverse * ndc
    return (SIMD3(world.x, world.y, world.z) / world.w - position).normalized
  }
}

extension Matrix4 {
  /// three's `Object3D.matrix` for the transforms the scenes use: a scale, a turn about one
  /// axis, then a position — in that order, as three composes them.
  public static func model(position: SIMD3<Float> = .zero, rotationX: Float = 0, scale: Float = 1)
    -> Matrix4
  {
    let c = cos(rotationX)
    let s = sin(rotationX)
    return Matrix4(
      SIMD4(scale, 0, 0, 0),
      SIMD4(0, c * scale, s * scale, 0),
      SIMD4(0, -s * scale, c * scale, 0),
      SIMD4(position.x, position.y, position.z, 1))
  }

  /// three's Euler rotation in its default XYZ order, then a position: `RX · RY · RZ`.
  public static func model(position: SIMD3<Float>, rotation: SIMD3<Float>) -> Matrix4 {
    let (sx, cx) = (sin(rotation.x), cos(rotation.x))
    let (sy, cy) = (sin(rotation.y), cos(rotation.y))
    let (sz, cz) = (sin(rotation.z), cos(rotation.z))
    return Matrix4(
      SIMD4(cy * cz, cx * sz + cz * sx * sy, sx * sz - cx * cz * sy, 0),
      SIMD4(-cy * sz, cx * cz - sx * sy * sz, cz * sx + cx * sy * sz, 0),
      SIMD4(sy, -cy * sx, cx * cy, 0),
      SIMD4(position.x, position.y, position.z, 1))
  }
}

/// How far back to sit so a subject fills the frame. A perspective camera's field of view
/// is *vertical*, so the horizontal extent it can see is that times the aspect: narrow the
/// window and width is the binding constraint, widen it and height is. Solving both and
/// taking the larger fits either way round. The extents are the subject's size *on screen*,
/// not in space — a ring system seen almost edge on is as wide as its radius and a fraction
/// as tall. Never past the far plane: cropping shows part of something, and being beyond
/// the far plane shows nothing at all.
public func fitDistance(
  camera: Camera, aspect: Float, halfWidth: Float, halfHeight: Float, fill: Float = 0.9
) -> Float {
  let halfFov = tan(camera.fovDegrees * .pi / 360)
  let want = max(halfHeight / halfFov, halfWidth / (halfFov * aspect)) / fill
  let ceiling = camera.far - max(halfWidth, halfHeight) * 1.6
  return min(want, max(1, ceiling))
}

/// Onset detection: a fast envelope crossing a slow one, so something lands on hits rather
/// than on loudness. A threshold on the level itself fires constantly through a loud
/// passage and never through a quiet one.
public struct Onset {
  public var rise: Float
  public var refractory: Float
  public var rates: SIMD2<Float>
  public var floor: Float
  private var fast: Float = 0
  private var slow: Float = 0
  private var wait: Float = 0

  public init(
    rise: Float, refractory: Float, rates: SIMD2<Float> = SIMD2(28, 2.2), floor: Float = 0.07
  ) {
    self.rise = rise
    self.refractory = refractory
    self.rates = rates
    self.floor = floor
  }

  /// How hard it was hit, or zero.
  public mutating func detect(_ value: Float, dt: Float) -> Float {
    fast += (value - fast) * min(1, dt * rates.x)
    slow += (value - slow) * min(1, dt * rates.y)
    wait -= dt
    if wait > 0 || fast < floor || fast < slow * rise { return 0 }
    wait = refractory
    return min(1, fast)
  }
}

/// A small deterministic generator, where a scene wants the web's own arbitrary sequence.
public struct Roll {
  private var state: Double
  public init(seed: Double) { state = seed }
  public mutating func next() -> Float {
    state = (state * 9301 + 0.49297).truncatingRemainder(dividingBy: 1)
    return Float(state)
  }
}

/// The linear congruential generator the point clouds are laid out with.
public struct Noise {
  private var seed: UInt64
  public init(seed: UInt64) { self.seed = seed }
  public mutating func next() -> Float {
    seed = (seed &* 1_664_525 &+ 1_013_904_223) % 4_294_967_296
    return Float(Double(seed) / 4_294_967_296)
  }
}

/// Symmetric smoothing, for a field of objects where an instant onset looks like a flash.
public func glide(_ current: Float, toward target: Float, dt: Float, attack: Float, release: Float)
  -> Float
{
  current + (target - current) * min(1, dt * (target > current ? attack : release))
}

/// three's `BoxGeometry` at one segment a side: six quads with their outward normals.
public enum Box {
  public static func build(width: Float, height: Float, depth: Float) -> (
    positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]
  ) {
    let half = SIMD3(width, height, depth) / 2
    let faces: [(normal: SIMD3<Float>, across: SIMD3<Float>, up: SIMD3<Float>)] = [
      (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
      (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
      (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
      (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
      (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
      (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
    ]
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    for face in faces {
      let centre = face.normal * half
      let across = face.across * half
      let up = face.up * half
      let first = UInt32(positions.count)
      for corner in [(-1, 1), (1, 1), (1, -1), (-1, -1)] as [(Float, Float)] {
        positions.append(centre + across * corner.0 + up * corner.1)
        normals.append(face.normal)
      }
      indices.append(contentsOf: [first, first + 1, first + 2, first, first + 2, first + 3])
    }
    return (positions, normals, indices)
  }
}

/// three's `IcosahedronGeometry`: the solid's twenty faces subdivided `detail` times and
/// pushed out to the sphere, in three's own order, and not indexed — as three leaves it.
public enum Icosahedron {
  public static func build(radius: Float = 1, detail: Int = 0) -> [SIMD3<Float>] {
    let t = (1 + Float(5).squareRoot()) / 2
    let corners: [SIMD3<Float>] = [
      SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
      SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
      SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
    ]
    let faces = [
      0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
      1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
      3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
      4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
    ]
    var out: [SIMD3<Float>] = []
    let cols = detail + 1
    for face in stride(from: 0, to: faces.count, by: 3) {
      let a = corners[faces[face]]
      let b = corners[faces[face + 1]]
      let c = corners[faces[face + 2]]
      // A triangular lattice across the face, row by row toward `c`.
      var rowsOfPoints: [[SIMD3<Float>]] = []
      for i in 0...cols {
        let aj = a.mix(c, Float(i) / Float(cols))
        let bj = b.mix(c, Float(i) / Float(cols))
        let rows = cols - i
        var points: [SIMD3<Float>] = []
        for j in 0...rows {
          if j == 0 && i == cols {
            points.append(aj)
          } else {
            points.append(aj.mix(bj, Float(j) / Float(rows)))
          }
        }
        rowsOfPoints.append(points)
      }
      for i in 0..<cols {
        for j in 0..<(2 * (cols - i) - 1) {
          let k = j / 2
          if j % 2 == 0 {
            out.append(contentsOf: [rowsOfPoints[i][k + 1], rowsOfPoints[i + 1][k], rowsOfPoints[i][k]])
          } else {
            out.append(
              contentsOf: [rowsOfPoints[i][k + 1], rowsOfPoints[i + 1][k + 1], rowsOfPoints[i + 1][k]])
          }
        }
      }
    }
    return out.map { $0.normalized * radius }
  }
}

/// three's `PlaneGeometry`: a grid in the xy plane, with uvs from the bottom left and two
/// triangles per cell, in three's own vertex and index order.
public enum Plane {
  public static func build(width: Float, height: Float, segments: SIMD2<Int> = SIMD2(1, 1)) -> (
    positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]
  ) {
    var positions: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    let across = max(1, segments.x)
    let down = max(1, segments.y)
    for iy in 0...down {
      let y = Float(iy) / Float(down) * height - height / 2
      for ix in 0...across {
        let x = Float(ix) / Float(across) * width - width / 2
        positions.append(SIMD3(x, -y, 0))
        uvs.append(SIMD2(Float(ix) / Float(across), 1 - Float(iy) / Float(down)))
      }
    }
    for iy in 0..<down {
      for ix in 0..<across {
        let a = UInt32(ix + (across + 1) * iy)
        let b = UInt32(ix + (across + 1) * (iy + 1))
        let c = UInt32(ix + 1 + (across + 1) * (iy + 1))
        let d = UInt32(ix + 1 + (across + 1) * iy)
        indices.append(contentsOf: [a, b, d, b, c, d])
      }
    }
    return (positions, uvs, indices)
  }
}
