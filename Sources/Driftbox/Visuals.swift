#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(Metal)
  import DriftboxEngine
  import DriftboxScenes
  import MetalKit
  import SwiftUI

  /// The scene for the song playing, drawn at the display's rate from what the engine reports.
  struct Visuals: NSViewRepresentable {
    let player: Player

    func makeNSView(context: Context) -> MTKView {
      let view = MTKView()
      view.device = MTLCreateSystemDefaultDevice()
      view.colorPixelFormat = .bgra8Unorm
      view.preferredFramesPerSecond = 60
      view.delegate = context.coordinator
      context.coordinator.view = view
      return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
      context.coordinator.sceneId = player.song?.visual
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
      let player: Player
      weak var view: MTKView?
      var renderer: SceneRenderer?
      var sceneId: String? {
        didSet { try? renderer?.show(sceneId) }
      }

      init(player: Player) {
        self.player = player
        renderer = try? SceneRenderer(now: CACurrentMediaTime())
        super.init()
      }

      func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

      func draw(in view: MTKView) {
        guard let renderer, let drawable = view.currentDrawable else { return }
        let peaks = player.peaks
        let position = player.position
        let analyser = player.analyse()
        let input = SceneInput(
          time: CACurrentMediaTime(), peakLeft: peaks.left, peakRight: peaks.right,
          events: player.takeEvents(), touch: player.padTouch, bar: position?.bar ?? 0,
          step: position?.step ?? 0, running: player.isPlaying, bpm: player.tempo,
          scoreBeat: player.scoreBeat(), levels: analyser?.levels() ?? (0, 0, 0),
          wideLevels: analyser?.wideLevels() ?? (0, 0))
        renderer.draw(input, into: drawable.texture, drawable: drawable)
      }
    }
  }
#endif
