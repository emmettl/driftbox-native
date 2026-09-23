import DriftboxGPU

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

  init(device: any GPUDevice) throws
  /// One frame into `target`, which it covers.
  func draw(_ input: SceneInput, into target: any GPUTarget, on device: any GPUDevice)
}
