#if canImport(Metal)
  import DriftboxEngine
  import Metal
  import simd

  /// What a scene hears and feels, once per frame it draws.
  public struct SceneInput {
    /// Seconds since the scene started.
    public var time: Double
    /// The loudest sample of the last audio block, 0...1, each side.
    public var peakLeft: Float
    public var peakRight: Float
    /// Hits and notes since the last frame, from the engine's events ring.
    public var events: [EngineEvent]
    /// Where the pad is being touched, 0...1 from the bottom left, or nil.
    public var touch: SIMD2<Float>?
    /// Which bar and step the transport is on, for scenes that count.
    public var bar: Int
    public var step: Int

    public init(
      time: Double, peakLeft: Float = 0, peakRight: Float = 0, events: [EngineEvent] = [],
      touch: SIMD2<Float>? = nil,
      bar: Int = 0, step: Int = 0
    ) {
      self.time = time
      self.peakLeft = peakLeft
      self.peakRight = peakRight
      self.events = events
      self.touch = touch
      self.bar = bar
      self.step = step
    }
  }

  /// A scene: what a song is seen with. It keeps the id the web app's scene of the same intent
  /// has, so a song's `visual` hint resolves here too, and the accent colour the pad's cursor
  /// draws in. What it draws is its own affair.
  public protocol Scene: AnyObject {
    static var id: String { get }
    static var name: String { get }
    /// `r, g, b`, 0...1.
    static var accent: SIMD3<Float> { get }

    init(device: MTLDevice, library: MTLLibrary) throws
    /// Draw one frame into `target`, which is `size` pixels.
    func draw(_ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer)
  }

  /// The scenes there are, by id, and the one a song gets when the one it names is not here yet.
  public enum Scenes {
    public static let all: [Scene.Type] = [Pulse.self]
    public static let fallback: Scene.Type = Pulse.self

    public static func type(for id: String?) -> Scene.Type {
      all.first { $0.id == id } ?? fallback
    }
  }
#endif
