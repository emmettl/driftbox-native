#if canImport(Metal)
  import DriftboxEngine
  import Metal
  import simd

  /// The fallback scene. See the shader for what it draws.
  public final class Pulse: Scene {
    public static let id = "pulse"
    public static let name = "Pulse"
    public static let accent = SIMD3<Float>(1.0, 0.62, 0.2)

    struct Uniforms {
      var time: Float = 0
      var peak: Float = 0
      var sinceKick: Float = 1000
      var sinceSnare: Float = 1000
      var sinceHat: Float = 1000
      var sinceNote: Float = 1000
      var notePitch: Float = 0
      var touch = SIMD2<Float>(-1, -1)
      var size = SIMD2<Float>(1, 1)
      var accent = Pulse.accent
    }

    let pipeline: MTLRenderPipelineState
    var uniforms = Uniforms()
    var lastKick = -1000.0
    var lastSnare = -1000.0
    var lastHat = -1000.0
    var lastNote = -1000.0

    public init(device: MTLDevice, library: MTLLibrary) throws {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
      descriptor.fragmentFunction = library.makeFunction(name: "pulse")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
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
      uniforms.size = SIMD2<Float>(Float(size.x), Float(size.y))

      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
    }
  }
#endif
