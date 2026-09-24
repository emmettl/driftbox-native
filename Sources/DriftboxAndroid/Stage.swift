#if os(Android)
  import Android
  import CGLES
  import DriftboxGPU
  import DriftboxGPUGLES
  import DriftboxHost
  import DriftboxHostAndroid
  import DriftboxSession
  import DriftboxShell
  import DriftboxText
  import DriftboxTouch
  import Synchronization

  /// A song, played and seen and edited: the session playing it through AAudio, and the touch
  /// screen — the song's scene, the controls over it, the rest of the screen the pad — drawn on the
  /// phone's screen.
  ///
  /// All of it on Java's main thread, which is the main actor's, as the desktop's is on its window's:
  /// Java's `Choreographer` asks for each frame, and hands over each finger, between them. Only the
  /// audio has a thread of its own.
  @MainActor
  final class Stage {
    private let host: EngineHost
    private let route: AAudioRoute
    private let lost = Flag()
    let session: Session
    private let device: GLESDevice
    private let screen: Touchscreen
    private var surface: (any GPUSurface)?
    private var drawing = true
    private var frames = 0
    private var said = "starting"

    /// The catalogue's song `id` played, with the scene called `scene` drawn from it, or the one the
    /// song names, on a screen of `density` pixels to a point.
    init?(song id: String, scene: String?, density: Float, typesetter: any Typesetter) {
      guard let entry = Catalogue.entries().first(where: { $0.id == id }) else { return nil }
      host = EngineHost(sampleRate: 48000)
      route = AAudioRoute(hop: { [lost] _ in lost.raise() })
      session = Session(host: host, audio: route)
      session.open(entry)
      guard session.song != nil, let device = try? GLESDevice(),
        let screen = try? Touchscreen(
          session: session, device: device, typesetter: typesetter, scale: density, scene: scene)
      else {
        session.close()
        return nil
      }
      self.device = device
      self.screen = screen
      screen.onMenu = { [weak self, interface = screen.interface] menu, at in
        self?.pendingMenu = MenuLines.write(
          menu, at: at, isEnabled: interface.menuIsEnabled, isChecked: interface.menuIsChecked)
      }
    }

    /// Stop playing and drawing, and let go of the window.
    func stop() {
      surface = nil
      session.close()
    }

    /// Draw, or draw nothing: the app in view, or out of it. The song plays on either way, since the
    /// app's playback service keeps the process on the big cores while it is out of view.
    func setDrawing(_ drawing: Bool) {
      self.drawing = drawing
      // Unseen, nobody hears how late the sound is, only whether it breaks.
      route.relaxed = !drawing
    }

    /// Play, or pause: the song stops where it is and the audio stream is let go of, as for a call
    /// or another app's playing, until it plays again.
    func setPlaying(_ playing: Bool) {
      if playing {
        route.resume()
        session.play()
      } else {
        session.stop()
        route.suspend()
      }
    }

    func show(window: OpaquePointer, width: Int, height: Int) {
      surface = nil
      do {
        surface = try device.makeSurface(window: window, width: width, height: height)
        said = "on a screen \(width) by \(height) on \(device.renderer)"
      } catch {
        said = "with no surface: \(error)"
      }
    }

    /// Let go of the window, which Android wants before its `surfaceDestroyed` returns.
    func hide() {
      surface = nil
      said = "with no window"
    }

    /// A frame, when the display is ready for one.
    func frame() {
      guard drawing, let surface else { return }
      do {
        try screen.draw(into: surface)
        frames += 1
      } catch {
        said = "that could not be shown: \(error)"
      }
    }

    /// A finger, in points from the top left: `phase` 0 down, 1 moved, 2 lifted, 3 taken away.
    func touch(id: Int, phase: Int, x: Float, y: Float) {
      let phases: [PointerEvent.Phase] = [.began, .moved, .ended, .cancelled]
      guard phases.indices.contains(phase) else { return }
      screen.touch(PointerEvent(phase: phases[phase], id: id, kind: .touch, location: SIMD2(x, y)))
    }

    /// Once a second: the route kept on its device and its buffer tuned, the session caught up
    /// while nothing is drawn to catch it up, and a line saying how it is going.
    func tick() -> String {
      if lost.take() { route.apply() }
      route.tune()
      if !drawing || surface == nil { session.tick() }
      let load = host.takeLoad()
      defer { frames = 0 }
      // The slowest callback too, in tenths of a millisecond: one over its burst is a crackle, which
      // a second's average hides.
      let longest = Int((load.longestMilliseconds * 10).rounded())
      return
        "\(frames) frames of \(screen.sceneID) \(said), render \(Int(load.fraction * 100))% of the audio's "
        + "time, longest \(longest / 10).\(longest % 10)ms, \(route.xruns) underruns, "
        + (route.details ?? route.error ?? "")
    }

    /// A long press's menu, waiting for Java to show it as its own; see `MenuLines`.
    private var pendingMenu: String?

    /// The menu a long press has asked for since the last frame, as lines Java reads, or nil.
    func takeMenu() -> String? {
      defer { pendingMenu = nil }
      return pendingMenu
    }

    /// What was chosen from it.
    func choose(_ id: String) {
      screen.interface.choose(id)
    }
  }

  /// Raised from AAudio's thread when the stream's device goes, and taken on the main thread.
  final class Flag: Sendable {
    private let raised = Atomic<Bool>(false)
    func raise() { raised.store(true, ordering: .releasing) }
    func take() -> Bool { raised.exchange(false, ordering: .acquiringAndReleasing) }
  }
#endif
