#if canImport(Metal)
  import DriftboxEngine
  import Metal
  import simd

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
    // Tables of types, made once and never changed: nothing about them can race, which the
    // compiler cannot see because a scene's type is not itself `Sendable`.
    nonisolated(unsafe) public static let all: [Scene.Type] = [Pulse.self] + surfaces + geometry
    nonisolated(unsafe) public static let fallback: Scene.Type = Pulse.self

    /// The web's material studies, ported shader for shader.
    static let surfaces: [SurfaceScene.Type] = [
      Orrery.self, Switchback.self, Daydream.self, SmallHours.self, PaperCities.self, Weave.self, Frost.self,
      Hothouse.self, NightBus.self,
    ]
    /// The web's three.js scenes, reinterpreted over the geometry layer.
    static let geometry: [GeometryScene.Type] = [
      Wireframe.self, Sunset.self, Web.self, Saturn.self, Lifeforms.self, Cubik.self, Stillwater.self,
      Cycles.self, Clouds.self, Longhand.self, Defcon.self, Dancers.self, Convoy.self, Machine.self,
      Jumpman.self, Trench.self, GraphicLab.self,
    ]
    static var geometrySources: String {
      GeometryScene.preamble
        + [
          Wireframe.source, Sunset.source, Web.source, Saturn.source, Lifeforms.source, Cubik.source,
          Stillwater.source, Cycles.source, Clouds.source, Longhand.source, Defcon.source, Dancers.source,
          Convoy.source, Machine.source, Jumpman.source, Trench.source, GraphicLab.source,
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
