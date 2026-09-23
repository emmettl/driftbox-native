import DriftboxGPU

/// Printed paper, lit along the cut edges. The camera stays above a layered town; the
/// foreground folds away under a finger, revealing streets further back.
public final class PaperCitiesScene: GPUSurfaceScene {
  override public class var id: String { "papercities" }
  override public class var name: String { "Paper Cities" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 238, 194) / 255 }
  override public class var program: ShaderProgram { .papercities }
}
