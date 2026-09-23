import DriftboxGPU

/// The camera is the passenger: upstairs, after midnight, watching sodium lamps and lit
/// windows slide past wet glass. The city moves steadily, bass makes each lamp bloom, and hats
/// pull rain down the pane faster than either. Touch does not steer the bus: it wipes a clear
/// patch in the condensation.
///
/// A surface with its own clocks: time runs faster with the highs and travel with the bass,
/// and the bands are the web's `readLevels` rather than its eight bands.
public final class NightBusScene: GPUSurfaceScene {
  override public class var id: String { "nightbus" }
  override public class var name: String { "Night Bus" }
  override public class var accent: SIMD3<Float> { SIMD3(255, 232, 190) / 255 }
  override public class var program: ShaderProgram { .nightbus }

  override func advance(_ input: SceneInput, size: SIMD2<Int>) {
    let dt = Float(min(input.time - (lastTime ?? input.time), 0.1))
    let travel = uniforms.uTravel
    let time = uniforms.uTime
    super.advance(input, size: size)
    let levels = input.wideLevels
    uniforms.uTime = time + dt * (0.72 + levels.high * 2.8)
    uniforms.uTravel = input.running ? travel + dt * (0.035 + levels.bass * 0.08) : travel
    uniforms.uBass = Analyser.ease(bass, toward: levels.bass, dt: dt, fall: 3.4)
    uniforms.uHigh = Analyser.ease(high, toward: levels.high, dt: dt, fall: 4.8)
    bass = uniforms.uBass
    high = uniforms.uHigh
  }

  private var bass: Float = 0
  private var high: Float = 0
}
