import DriftboxGPU

/// A dawn behind frosted glass, and eleven ice crystals that grow with the mids and pulse with
/// each hit; a finger's warmth clears them.
public final class FrostScene: GPUSurfaceScene {
  override public class var id: String { "frost" }
  override public class var name: String { "Frost" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 202, 133) / 255 }
  override public class var program: ShaderProgram { .frost }
  override public class var cardProgram: ShaderProgram? { .frostCards }
  override public class var cardCount: Int { placements.count }

  static let placements: [(x: Float, y: Float, scale: Float)] = [
    (0.02, 0.3, 0.38), (0.04, 0.65, 0.34), (0.17, 0.94, 0.38), (0.52, 1.04, 0.42),
    (0.88, 0.93, 0.38), (0.99, 0.64, 0.38), (0.99, 0.27, 0.4), (0.66, 0.02, 0.32),
    (0.27, 0.03, 0.3), (0.26, 0.47, 0.19), (0.74, 0.53, 0.2),
  ]

  override public func cards(aspect: Float) -> [Matrix4] {
    Self.placements.enumerated().map { index, place in
      Self.compose(
        x: (place.x - 0.5) * aspect, y: place.y, z: Float(index), angle: Float(index) * 0.71,
        scale: SIMD2(place.scale, place.scale))
    }
  }
}
