import DriftboxGPU
import DriftboxText

/// A scene drawn through the GPU layer rather than straight into Metal, and so on every platform
/// the layer has a backend for. What a scene is does not change — an id a song's `visual` hint
/// names, an accent, a frame drawn from a `SceneInput` — only what it draws with.
///
/// The Metal `Scene` and this stand side by side while the scenes move across, which they do once
/// the Metal backend can carry them: then `Scene` goes, and this takes its name.
public protocol GPUScene: AnyObject {
  static var id: String { get }
  static var name: String { get }
  /// `r, g, b`, 0...1.
  static var accent: SIMD3<Float> { get }

  /// Made once, with the GPU it draws on and the platform's type, which the app chooses. Only a
  /// scene that sets type uses the typesetter; a platform with none yet gives a `NoTypesetter`.
  init(device: any GPUDevice, typesetter: any Typesetter) throws
  /// One frame into `target`, which it covers.
  func draw(_ input: SceneInput, into target: any GPUTarget, on device: any GPUDevice)
}

/// The scenes on the GPU layer, by id, and the one a song gets when the one it names has not moved
/// across yet. `Scenes`, as it will be once every scene has.
public enum GPUScenes {
  // Tables of types, made once and never changed, as `Scenes` has them: nothing about them can
  // race, which the compiler cannot see because a scene's type is not itself `Sendable`.
  nonisolated(unsafe) public static let all: [any GPUScene.Type] =
    [PulseScene.self] + surfaces + geometry
  nonisolated(unsafe) public static let fallback: any GPUScene.Type = PulseScene.self

  /// The web's material studies, in the order `Scenes.surfaces` has them.
  static let surfaces: [GPUSurfaceScene.Type] = [
    OrreryScene.self, SwitchbackScene.self, DaydreamScene.self, SmallHoursScene.self,
    PaperCitiesScene.self, WeaveScene.self, FrostScene.self, HothouseScene.self, NightBusScene.self,
  ]
  /// The web's three.js scenes, in the order `Scenes.geometry` has them.
  static let geometry: [GPUGeometryScene.Type] = [
    WireframeScene.self, SunsetScene.self, WebScene.self, SaturnScene.self, LifeformsScene.self,
    CubikScene.self, StillwaterScene.self, CyclesScene.self, CloudsScene.self, LonghandScene.self,
    DefconScene.self, DancersScene.self, ConvoyScene.self, MachineScene.self, JumpmanScene.self,
    TrenchScene.self, GraphicLabScene.self,
  ]

  public static func type(for id: String?) -> any GPUScene.Type {
    all.first { $0.id == id } ?? fallback
  }
}
