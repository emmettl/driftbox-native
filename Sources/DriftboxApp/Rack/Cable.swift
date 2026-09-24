#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRackSession
  import SwiftUI

  /// A cable as SwiftUI draws it: the curve `DriftboxRackSession`'s `Cable` hangs, as a path.
  extension Cable {
    static func path(_ from: CGPoint, _ to: CGPoint, angle: Double = 0) -> Path {
      let (c1, c2) = controls(from, to, angle: angle)
      var path = Path()
      path.move(to: from)
      path.addCurve(to: to, control1: c1, control2: c2)
      return path
    }
  }
#endif
