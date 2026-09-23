import DriftboxEngine
import DriftboxGPU
import Foundation

/// The fallback scene on the GPU layer: the first scene to move across, and so the first to draw on
/// Windows. The same scene as the Metal `Pulse` — the shader is its GLSL, line for line — and the
/// same moments: a kick, a snare, a hat and a note, each remembered from the events that played it.
/// See `shaders/DriftboxScenes/pulse.frag` for what it draws.
public final class PulseScene: GPUScene {
  public static let id = "pulse"
  public static let name = "Pulse"
  public static let accent = SIMD3<Float>(1.0, 0.62, 0.2)

  private let pipeline: any GPUPipeline
  private var uniforms = PulseUniforms()
  private var lastKick = -1000.0
  private var lastSnare = -1000.0
  private var lastHat = -1000.0
  private var lastNote = -1000.0

  public init(device: any GPUDevice) throws {
    pipeline = try device.makePipeline(GPUPipelineDescriptor(program: .pulse))
    uniforms.accent = Self.accent
  }

  public func draw(_ input: SceneInput, into target: any GPUTarget, on device: any GPUDevice) {
    for event in input.events {
      switch event.kind {
      case .hit:
        let voice = allVoices[event.voice].id
        if voice.hasSuffix(".bd") { lastKick = input.time }
        if voice.hasSuffix(".sd") || voice.hasSuffix(".cp") { lastSnare = input.time }
        if voice.hasSuffix(".ch") || voice.hasSuffix(".oh") { lastHat = input.time }
      case .note:
        lastNote = input.time
        // 27.5Hz to 220Hz is the 303's two octaves either side of its root.
        uniforms.notePitch = Float(max(0, min(1, (log2(Double(event.frequency) / 27.5)) / 3)))
      case .pass:
        break
      }
    }
    uniforms.time = Float(input.time)
    uniforms.peak = max(input.peakLeft, input.peakRight)
    uniforms.sinceKick = Float(input.time - lastKick)
    uniforms.sinceSnare = Float(input.time - lastSnare)
    uniforms.sinceHat = Float(input.time - lastHat)
    uniforms.sinceNote = Float(input.time - lastNote)
    uniforms.touch = input.touch ?? SIMD2<Float>(-1, -1)
    uniforms.size = SIMD2<Float>(Float(target.width), Float(target.height))
    device.render(into: target, clear: .colour(SIMD4(0, 0, 0, 1))) { pass in
      pass.setPipeline(pipeline)
      pass.setUniforms(uniforms, binding: 0)
      pass.draw(vertexCount: 3)
    }
  }
}
