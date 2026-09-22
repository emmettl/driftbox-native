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
    /// Whether the transport is running: scenes that travel stand still when it is not.
    public var running: Bool
    /// The transport's tempo, so a scene can dance on the record rather than near it.
    public var bpm: Double
    /// Where the song is in quarter notes from the top, when it is somewhere.
    public var scoreBeat: Double?
    /// The mix's bass, mids and highs, 0...1, from the `Analyser`'s eight bands.
    public var levels: (bass: Float, mid: Float, high: Float)
    /// The backing scale of what is being drawn into, for anything sized in points.
    public var pixelRatio: Float
    /// The spectrum in sixteen bands of constant ratio, for a scene with one lane each.
    public var bands: [Float]
    /// The web's other reading of the same spectrum — the bottom few bins and the top half —
    /// for the scenes written against `readLevels`.
    public var wideLevels: (bass: Float, high: Float)

    public init(
      time: Double, peakLeft: Float = 0, peakRight: Float = 0, events: [EngineEvent] = [],
      touch: SIMD2<Float>? = nil, bar: Int = 0, step: Int = 0, running: Bool = false, bpm: Double = 120,
      scoreBeat: Double? = nil, levels: (bass: Float, mid: Float, high: Float) = (0, 0, 0),
      wideLevels: (bass: Float, high: Float) = (0, 0), bands: [Float] = [], pixelRatio: Float = 1
    ) {
      self.time = time
      self.peakLeft = peakLeft
      self.peakRight = peakRight
      self.events = events
      self.touch = touch
      self.bar = bar
      self.step = step
      self.running = running
      self.bpm = bpm
      self.scoreBeat = scoreBeat
      self.levels = levels
      self.wideLevels = wideLevels
      self.bands = bands
      self.pixelRatio = pixelRatio
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
    public static let all: [Scene.Type] = [Pulse.self] + surfaces + geometry
    public static let fallback: Scene.Type = Pulse.self

    /// The web's material studies, ported shader for shader.
    static let surfaces: [SurfaceScene.Type] = [
      Orrery.self, Switchback.self, Daydream.self, SmallHours.self, PaperCities.self, Weave.self, Frost.self,
      Hothouse.self, NightBus.self,
    ]
    /// The web's three.js scenes, reinterpreted over the geometry layer.
    static let geometry: [GeometryScene.Type] = [
      Wireframe.self, Sunset.self, Web.self, Saturn.self, Lifeforms.self, Cubik.self, Stillwater.self,
      Cycles.self, Clouds.self, Longhand.self, Defcon.self, Dancers.self, Convoy.self, Machine.self,
      Jumpman.self,
    ]
    static var geometrySources: String {
      GeometryScene.preamble
        + [
          Wireframe.source, Sunset.source, Web.source, Saturn.source, Lifeforms.source, Cubik.source,
          Stillwater.source, Cycles.source, Clouds.source, Longhand.source, Defcon.source, Dancers.source,
          Convoy.source, Machine.source, Jumpman.source,
        ]
        .joined()
    }

    static var surfaceSources: String {
      [
        Orrery.source, Switchback.source, Daydream.source, SmallHours.source, PaperCities.source,
        Weave.source, Frost.source, Hothouse.source, NightBus.source,
      ]
      .joined()
    }

    public static func type(for id: String?) -> Scene.Type {
      all.first { $0.id == id } ?? fallback
    }
  }
#endif
