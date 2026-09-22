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

    /// One frame, drawn and committed. `now` is on the same clock `init` was given.
    public func draw(
      into target: MTLTexture, now: Double, peakLeft: Float, peakRight: Float, events: [EngineEvent],
      touch: SIMD2<Float>? = nil, bar: Int = 0, step: Int = 0, drawable: MTLDrawable? = nil
    ) {
      guard let commandBuffer = queue.makeCommandBuffer() else { return }
      let input = SceneInput(
        time: now - started, peakLeft: peakLeft, peakRight: peakRight, events: events, touch: touch, bar: bar,
        step: step)
      scene.draw(input, into: target, size: SIMD2(target.width, target.height), commandBuffer: commandBuffer)
      if let drawable { commandBuffer.present(drawable) }
      commandBuffer.commit()
    }

    public enum SceneError: Error {
      case noDevice
    }
  }
#endif
