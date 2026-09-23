import DriftboxGPU

/// A projected miniature landscape: three depths of scenery, slowly changing seasons, drifting
/// cloud shadows and an imperfectly registered image inside a physical slide.
public final class DaydreamScene: GPUSurfaceScene {
  override public class var id: String { "daydream" }
  override public class var name: String { "Daydream" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 228, 168) / 255 }
  override public class var program: ShaderProgram { .daydream }
}
