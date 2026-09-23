import DriftboxGPU

/// Three geared orbits share the score's 5-, 7- and 4-beat periods. The transport supplies the
/// position, so opening the scene mid-phrase or seeking preserves alignment.
public final class OrreryScene: GPUSurfaceScene {
  override public class var id: String { "orrery" }
  override public class var name: String { "Orrery" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 214, 142) / 255 }
  override public class var program: ShaderProgram { .orrery }
}
