import Foundation

/// How a cable hangs, and how it swings when the rack turns: a port of the reference's
/// `cable.ts`. A cubic with both control points pushed down, sagging more the further apart its
/// ends are, and after a flip a damped pendulum per cable, each with a period and a start of its
/// own so the panel comes loose in a ripple rather than as one sheet.
public enum Cable {
  /// Rest length beyond the straight line, and how much of the distance turns into sag.
  public static let slack = 22.0
  public static let droop = 0.1
  /// Design units a second squared: what spreads the cables' periods across the rack.
  public static let gravity = 4300.0
  /// How far the belly is thrown at the peak of the first swing, in radians.
  public static let throwAngle = 0.9
  /// How far sideways the belly can reach, as a base and a share of the sag.
  public static let reach = 20.0
  public static let reachPerSag = 1.4
  /// How much of the sag the belly gives up at full swing.
  public static let lift = 0.5
  /// The decay's time constant, in seconds.
  public static let damping = 0.5
  /// When the swing is under a pixel and can stop, in milliseconds.
  public static let swingMilliseconds = 2200.0
  /// The longest a cable waits before it starts to move, in milliseconds.
  public static let staggerMilliseconds = 70.0

  /// How far below the straight line between two points the cable hangs at its lowest.
  public static func sag(_ from: CGPoint, _ to: CGPoint) -> Double {
    slack + hypot(to.x - from.x, to.y - from.y) * droop
  }

  /// A stable number in [0, 1) for a cable, from its own name: FNV-1a over its UTF-16 units,
  /// as the reference hashes a string.
  public static func seed(_ key: String) -> Double {
    var hash: UInt32 = 2_166_136_261
    for unit in key.utf16 {
      hash ^= UInt32(unit)
      hash = hash &* 16_777_619
    }
    return Double(hash % 1000) / 1000
  }

  /// The key a cable is named by, and seeded from.
  public static func key(from: (String, String), to: (String, String)) -> String {
    "\(from.0).\(from.1)>\(to.0).\(to.1)"
  }

  /// One swing's length in milliseconds: a pendulum as long as the sag, varied ±15% by the
  /// cable's own seed so cables of a length do not move in lockstep.
  public static func period(_ from: CGPoint, _ to: CGPoint, seed: Double = 0) -> Double {
    let base = 2 * Double.pi * (sag(from, to) / gravity).squareRoot() * 1000
    return base * (0.85 + seed * 0.3)
  }

  /// The belly's angle `elapsed` milliseconds after the rack turned, one way (1) or the other
  /// (-1): started from rest with a kick, so `sin`, and decaying.
  public static func swing(
    _ elapsed: Double, _ from: CGPoint, _ to: CGPoint, direction: Double = 1, seed: Double = 0
  ) -> Double {
    let since = elapsed - seed * staggerMilliseconds
    if since < 0 || elapsed >= swingMilliseconds { return 0 }
    let decay = exp(-since / 1000 / damping)
    let phase = (2 * Double.pi * since) / period(from, to, seed: seed)
    return direction * throwAngle * decay * sin(phase)
  }

  /// The two control points, shared by drawing, grabbing and the smoke.
  public static func controls(_ from: CGPoint, _ to: CGPoint, angle: Double = 0) -> (CGPoint, CGPoint) {
    let drop = sag(from, to)
    let across = sin(angle) * (reach + drop * reachPerSag)
    let down = drop * (1 - lift * (1 - cos(angle)))
    let dx = to.x - from.x
    return (
      CGPoint(x: from.x + dx * 0.25 + across, y: from.y + down),
      CGPoint(x: to.x - dx * 0.25 + across, y: to.y + down)
    )
  }

  /// A point on the curve, `progress` of the way along.
  public static func point(_ from: CGPoint, _ to: CGPoint, at progress: Double, angle: Double = 0)
    -> CGPoint
  {
    let t = max(0, min(1, progress))
    let rest = 1 - t
    let (c1, c2) = controls(from, to, angle: angle)
    let a = rest * rest * rest
    let b = 3 * rest * rest * t
    let c = 3 * rest * t * t
    let d = t * t * t
    return CGPoint(
      x: a * from.x + b * c1.x + c * c2.x + d * to.x, y: a * from.y + b * c1.y + c * c2.y + d * to.y)
  }

  /// Where a cable is grabbed: halfway along, which moves with it while it swings.
  public static func middle(_ from: CGPoint, _ to: CGPoint, angle: Double = 0) -> CGPoint {
    point(from, to, at: 0.5, angle: angle)
  }
}
