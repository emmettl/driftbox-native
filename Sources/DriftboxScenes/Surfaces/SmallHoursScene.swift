import DriftboxGPU

/// The moving city is behind the glass. Each bead samples it again through a curved offset, so
/// passing lights actually bend inside droplets instead of sitting on top.
public final class SmallHoursScene: GPUSurfaceScene {
  override public class var id: String { "smallhours" }
  override public class var name: String { "Small Hours" }
  override public class var accent: SIMD3<Float> { SIMD3(143, 224, 223) / 255 }
  override public class var program: ShaderProgram { .smallhours }
}
