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

    public enum SceneError: Error {
      case noDevice
      /// A scene named a shader function the library does not have; the names it does have.
      case missingFunction(String, [String])
    }
  }
#endif
