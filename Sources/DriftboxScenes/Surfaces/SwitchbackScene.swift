import DriftboxGPU

/// Isometric stair ribbons, with a short sideways cut each bar. The colour stays steady through
/// a cut; percussion raises individual treads instead of flashing the whole field.
public final class SwitchbackScene: GPUSurfaceScene {
  override public class var id: String { "switchback" }
  override public class var name: String { "Switchback" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 250, 224) / 255 }
  override public class var program: ShaderProgram { .switchback }
}
