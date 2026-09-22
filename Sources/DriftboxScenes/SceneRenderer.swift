#if canImport(Metal)
  import DriftboxEngine
  import Metal
  import simd

  /// Owns the device, the compiled shaders and the scene playing, and draws frames into whatever
  /// texture it is given — a view's drawable, or an offscreen texture for a test.
  public final class SceneRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let library: MTLLibrary
    public private(set) var scene: Scene
    public private(set) var sceneType: Scene.Type
    let started: Double

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), sceneId: String? = nil, now: Double)
      throws
    {
      guard let device, let queue = device.makeCommandQueue() else { throw SceneError.noDevice }
      self.device = device
      self.queue = queue
      library = try device.makeLibrary(source: Shaders.source, options: nil)
      sceneType = Scenes.type(for: sceneId)
      scene = try sceneType.init(device: device, library: library)
      started = now
    }

    /// Change scene, keeping the clock.
    public func show(_ id: String?) throws {
      let type = Scenes.type(for: id)
      guard type != sceneType else { return }
      scene = try type.init(device: device, library: library)
      sceneType = type
    }

    /// One frame, drawn and committed. `input.time` is on the same clock `init` was given.
    public func draw(_ input: SceneInput, into target: MTLTexture, drawable: MTLDrawable? = nil) {
      guard let commandBuffer = queue.makeCommandBuffer() else { return }
      var input = input
      input.time -= started
      scene.draw(input, into: target, size: SIMD2(target.width, target.height), commandBuffer: commandBuffer)
      if let drawable { commandBuffer.present(drawable) }
      commandBuffer.commit()
    }

    // MARK: - Presenting a finished frame

    /// How much of `target` a frame of size `frame` covers on each axis once fitted inside it
    /// without distortion: one on the axis that fills, less than one on the one that is
    /// letterboxed. A scene is framed for the shape it was drawn at, so a preview of a
    /// projector's output shows the projector's picture with bars, not a picture of its own.
    public static func fit(_ frame: SIMD2<Float>, in target: SIMD2<Float>) -> SIMD2<Float> {
      guard frame.x > 0, frame.y > 0, target.x > 0, target.y > 0 else { return .zero }
      let frameAspect = frame.x / frame.y
      let targetAspect = target.x / target.y
      return frameAspect > targetAspect
        ? SIMD2(1, targetAspect / frameAspect) : SIMD2(frameAspect / targetAspect, 1)
    }

    /// The scale that covers `target` with `frame`, cropping whichever way it overhangs, in
    /// the same terms as `fit`. For a backdrop, where bars would look like a fault and the
    /// edges of the picture are not missed.
    public static func cover(_ frame: SIMD2<Float>, in target: SIMD2<Float>) -> SIMD2<Float> {
      guard frame.x > 0, frame.y > 0, target.x > 0, target.y > 0 else { return .zero }
      let frameAspect = frame.x / frame.y
      let targetAspect = target.x / target.y
      return frameAspect > targetAspect
        ? SIMD2(frameAspect / targetAspect, 1) : SIMD2(1, targetAspect / frameAspect)
    }

    private lazy var presentPipeline: MTLRenderPipelineState? = {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "presentVertex")
      descriptor.fragmentFunction = library.makeFunction(name: "presentFragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    /// Show a frame `draw` has already finished in another target — a view's drawable —
    /// fitted and centred, black around it. On the same queue as the drawing, so it can never
    /// read a frame before that frame is written.
    /// Show `frame` in `target`, whole and letterboxed, or `filling` it and cropped.
    public func present(
      _ frame: MTLTexture, into target: MTLTexture, drawable: MTLDrawable? = nil, filling: Bool = false
    ) {
      guard let presentPipeline, let commandBuffer = queue.makeCommandBuffer() else { return }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      pass.colorAttachments[0].storeAction = .store
      if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
        let shape = SIMD2(Float(frame.width), Float(frame.height))
        let room = SIMD2(Float(target.width), Float(target.height))
        var scale = filling ? Self.cover(shape, in: room) : Self.fit(shape, in: room)
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
      }
      if let drawable { commandBuffer.present(drawable) }
      commandBuffer.commit()
    }

    public enum SceneError: Error {
      case noDevice
      /// A scene named a shader function the library does not have; the names it does have.
      case missingFunction(String, [String])
    }
  }
#endif
