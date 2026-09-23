import DriftboxGPU

/// A cloth with real over/under crossings. Fifteen and sixteen advancing threads draw a
/// changing motif; dragging bows the fabric locally without moving its wooden frame.
public final class WeaveScene: GPUSurfaceScene {
  override public class var id: String { "weave" }
  override public class var name: String { "Weave" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 237, 196) / 255 }
  override public class var program: ShaderProgram { .weave }
}
