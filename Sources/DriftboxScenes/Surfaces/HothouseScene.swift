import DriftboxGPU
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// The glass and ironwork occupy a single surface. Leaves are instanced cards: a leaf shader
/// runs only where that leaf is drawn, instead of evaluating every leaf at every pixel.
public final class HothouseScene: GPUSurfaceScene {
  override public class var id: String { "hothouse" }
  override public class var name: String { "Hothouse" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 221, 154) / 255 }
  override public class var program: ShaderProgram { .hothouse }
  override public class var cardProgram: ShaderProgram? { .hothouseCards }
  override public class var cardCount: Int { 36 }

  override public func cards(aspect: Float) -> [Matrix4] {
    (0..<36).map { index in
      let n = index / 3
      let branch = index % 3
      let side = Float(n % 2) * 2 - 1
      let depth = Float(n / 2) / 6
      let x = side * (0.07 + depth * min(aspect * 0.65, 0.8))
      let y = 0.45 - depth * 0.52
      let tipX = side * (0.035 + depth * 0.12)
      let tipY = 0.13 + depth * 0.67
      let at = 0.42 + Float(branch) * 0.22
      let angle = side * (0.7 + Float(branch) * 0.52) + sin(Float(n)) * 0.3
      let scale = 0.035 + depth * 0.12
      return Self.compose(
        x: x + tipX * at - sin(angle) * scale * 0.75, y: y + tipY * at + cos(angle) * scale * 0.75,
        z: Float(n) + Float(branch) * 0.1, angle: angle, scale: SIMD2(scale / 1.7, scale / 0.78))
    }
  }
}
