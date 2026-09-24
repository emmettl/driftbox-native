#if os(Android)
  import Android
  import CGLES
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxGPU
  import DriftboxGPUGLES
  import DriftboxHost
  import DriftboxHostAndroid
  import DriftboxScenes
  import DriftboxSeq
  import DriftboxText
  import Synchronization

  /// A song, played and seen: the engine through AAudio, and the scene it names drawn from what it
  /// played on the phone's screen, as `driftbox-play --window` does on Windows and the Mac, with
  /// the whole screen a pad for the performance filter.
  ///
  /// Two threads. Java's main thread, which calls in, owns the engine's commands and the audio route,
  /// both of which are the main actor's; and a render thread of the `Renderer`'s own owns everything
  /// OpenGL, since a context is current on one thread, and reads the engine's events and its mix.
  @MainActor
  final class Stage {
    private let host: EngineHost
    private let route: AAudioRoute
    private let lost = Flag()
    private let renderer: Renderer

    /// `json` played, with the scene called `scene` drawn from it, or the one the song names, on
    /// a screen of `density` pixels to a point.
    init?(json: String, scene: String?, density: Float, typesetter: any Typesetter) {
      guard let song = SongCodec.decode(json) else { return nil }
      host = EngineHost(sampleRate: 48000)
      route = AAudioRoute(hop: { [lost] _ in lost.raise() })
      host.load(song)
      host.send(.play)
      route.attach(host.renderSource)
      renderer = Renderer(
        host: host, song: song, scene: scene ?? song.visual, density: density, typesetter: typesetter)
    }

    /// Stop drawing and playing, and wait until both have.
    func stop() {
      renderer.stop()
      route.detach(host.renderSource.context)
    }

    /// Draw, or draw nothing: the app in view, or out of it. The song plays on either way, since the
    /// app's playback service keeps the process on the big cores while it is out of view.
    func setDrawing(_ drawing: Bool) {
      renderer.paused.store(!drawing, ordering: .releasing)
      // Unseen, nobody hears how late the sound is, only whether it breaks.
      route.relaxed = !drawing
    }

    /// Play, or pause: the song stops where it is and the audio stream is let go of, as for a call
    /// or another app's playing, until it plays again.
    func setPlaying(_ playing: Bool) {
      if playing {
        route.resume()
        host.send(.play)
      } else {
        host.send(.stop)
        route.suspend()
      }
    }

    /// The next scene there is, as the Scene menu's next does on Windows.
    func nextScene() {
      renderer.steps.add(1, ordering: .releasing)
    }

    func show(window: OpaquePointer, width: Int, height: Int) {
      renderer.change(to: Renderer.Window(handle: window, width: width, height: height))
    }

    func hide() {
      renderer.change(to: nil)
    }

    /// A finger at `x, y`, 0...1 from the bottom left, or lifted: the performance filter's pad, and
    /// the scene feeling the finger where it is.
    func touch(x: Float, y: Float, down: Bool) {
      if down {
        host.send(.pad(x: Double(x), y: Double(y)))
        renderer.touch.withLock { $0 = SIMD2(x, y) }
      } else {
        host.send(.padRelease)
        renderer.touch.withLock { $0 = nil }
      }
    }

    /// Once a second: the route kept on its device and its buffer tuned, the songs the engine is
    /// done with freed, and a line saying how it is going.
    func tick() -> String {
      if lost.take() { route.apply() }
      route.tune()
      host.collect()
      let load = host.takeLoad()
      return
        "\(renderer.takeFrames()) frames \(renderer.status), render \(Int(load.fraction * 100))% of the audio's "
        + "time, \(route.xruns) underruns, \(route.details ?? route.error ?? "")"
    }
  }

  /// Raised from AAudio's thread when the stream's device goes, and taken on the main thread.
  final class Flag: Sendable {
    private let raised = Atomic<Bool>(false)
    func raise() { raised.store(true, ordering: .releasing) }
    func take() -> Bool { raised.exchange(false, ordering: .acquiringAndReleasing) }
  }

  /// The render thread: an OpenGL ES device, a scene, and the window it draws in when there is one.
  final class Renderer: @unchecked Sendable {
    /// What a scene is drawn at on a screen `width` by `height` pixels of `density` pixels to a
    /// point: no more than two pixels to a point, as a Mac's Retina display draws it, and scaled up
    /// to the screen as it is shown. A phone's screen is denser than that, and the scenes are soft
    /// enough not to show it: measured on a Fairphone 6, at its own 3, Frost took 21ms a frame
    /// at every pixel, and two others more than the display's 8.3.
    static func drawn(width: Int, height: Int, density: Float) -> (width: Int, height: Int, pixelRatio: Float)
    {
      let scale = min(1, 2 / max(density, 1))
      return (
        max(1, Int((Float(width) * scale).rounded())), max(1, Int((Float(height) * scale).rounded())),
        max(density, 1) * scale
      )
    }

    struct Window: @unchecked Sendable {
      var handle: OpaquePointer
      var width: Int
      var height: Int
    }

    private struct Change {
      var window: Window?
      var asked = 0
      var done = 0
    }

    private let host: EngineHost
    private let song: Song
    private let firstScene: String?
    private let density: Float
    /// What the scenes set their type with; Graphic Lab is the one that sets any.
    private let typesetter: any Typesetter
    private let changes = Mutex(Change())
    private let running = Atomic<Bool>(true)
    /// Set while the app is out of view: a window kept, but nothing drawn in it.
    let paused = Atomic<Bool>(false)
    /// Scenes to step on by, asked for and not yet taken.
    let steps = Atomic<Int>(0)
    private let frames = Atomic<Int>(0)
    private let said = Mutex("starting")
    let touch = Mutex<SIMD2<Float>?>(nil)
    private var thread = pthread_t()

    init(host: EngineHost, song: Song, scene: String?, density: Float, typesetter: any Typesetter) {
      self.host = host
      self.song = song
      firstScene = scene
      self.density = density
      self.typesetter = typesetter
      pthread_create(
        &thread, nil,
        { context in
          guard let context else { return nil }
          Unmanaged<Renderer>.fromOpaque(context).takeRetainedValue().run()
          return nil
        }, Unmanaged.passRetained(self).toOpaque())
    }

    /// What the render thread last said about itself.
    var status: String { said.withLock { $0 } }

    func takeFrames() -> Int { frames.exchange(0, ordering: .relaxed) }

    /// Draw in `window` from now on, or in nothing, and wait until the render thread has: Android
    /// wants a window it is taking away let go of before it says so.
    func change(to window: Window?) {
      let ticket = changes.withLock { change in
        change.window = window
        change.asked += 1
        return change.asked
      }
      while running.load(ordering: .acquiring), changes.withLock({ $0.done < ticket }) { pause(0.001) }
    }

    func stop() {
      running.store(false, ordering: .releasing)
      pthread_join(thread, nil)
    }

    private func run() {
      let device: GLESDevice
      let presenter: Presenter
      var scene: any GPUScene
      do {
        device = try GLESDevice()
        presenter = try Presenter(device: device)
        scene = try GPUScenes.type(for: firstScene).init(device: device, typesetter: typesetter)
      } catch {
        said.withLock { $0 = "no GPU: \(error)" }
        drainChanges()
        return
      }
      var surface: (any GPUSurface)?
      var frame: (any GPUTarget)?
      var pixelRatio = density
      var size = ""
      var seen = 0
      let began = HostTime.now()
      let timeline = Timeline(song: song)
      var events: [EngineEvent] = []
      // The mix's spectrum, as the other players keep it: worked out again only when new audio has
      // arrived, since the smoothing is per analysis and would otherwise follow the display's rate.
      let analyser = Analyser()
      var monitor = [Float](repeating: 0, count: Analyser.size)
      var analysedAt = -1
      func say() { said.withLock { $0 = "of \(type(of: scene).name) \(size) on \(device.renderer)" } }
      say()
      while running.load(ordering: .acquiring) {
        let (window, ticket) = changes.withLock { ($0.window, $0.asked) }
        if ticket != seen {
          surface = nil
          frame = nil
          size = "with no window"
          if let window {
            do {
              surface = try device.makeSurface(
                window: window.handle, width: window.width, height: window.height)
              let drawn = Self.drawn(width: window.width, height: window.height, density: density)
              frame = try device.makeTarget(width: drawn.width, height: drawn.height)
              pixelRatio = drawn.pixelRatio
              size = "at \(drawn.width) by \(drawn.height) on a screen \(window.width) by \(window.height)"
            } catch {
              surface = nil
              size = "with no surface: \(error)"
            }
          }
          say()
          seen = ticket
          changes.withLock { $0.done = ticket }
        }
        let step = steps.exchange(0, ordering: .acquiringAndReleasing)
        if step != 0 {
          let all = GPUScenes.all
          let at = all.firstIndex { $0.id == type(of: scene).id } ?? 0
          let next = all[(at + step) % all.count]
          do {
            scene = try next.init(device: device, typesetter: typesetter)
          } catch {
            size = "and could not show \(next.name): \(error)"
          }
          say()
        }
        guard let surface, let frame, !paused.load(ordering: .acquiring) else {
          pause(0.01)
          continue
        }
        events.removeAll(keepingCapacity: true)
        while let event = host.nextEvent() { events.append(event) }
        if host.mixWritten != analysedAt {
          analysedAt = host.mixWritten
          monitor.withUnsafeMutableBufferPointer { buffer in
            host.recentMix(Analyser.size, into: buffer.baseAddress!)
            analyser.update(UnsafeBufferPointer(buffer))
          }
        }
        let songFrame = host.songFrame.load(ordering: .relaxed)
        let input = SceneInput(
          time: HostTime.seconds(from: began, to: HostTime.now()),
          peakLeft: Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          peakRight: Float(bitPattern: host.peakRight.load(ordering: .relaxed)), events: events,
          touch: touch.withLock { $0 }, running: host.playing.load(ordering: .relaxed), bpm: song.bpm,
          scoreBeat: songFrame < 0 ? nil : timeline.scoreBeat(at: Double(songFrame) / host.sampleRate),
          levels: analyser.levels(), wideLevels: analyser.wideLevels(), bands: analyser.bands(16),
          pixelRatio: pixelRatio)
        scene.draw(input, into: frame, on: device)
        do {
          presenter.present(frame, into: try surface.target(), on: device)
          try surface.present()
          frames.add(1, ordering: .relaxed)
        } catch {
          said.withLock { $0 = "that could not be shown: \(error)" }
          pause(0.1)
        }
      }
      drainChanges()
    }

    /// Anybody still waiting on a change is let go: there is no window to hold on to any more.
    private func drainChanges() {
      while running.load(ordering: .acquiring) {
        changes.withLock { $0.done = $0.asked }
        pause(0.01)
      }
      changes.withLock { $0.done = $0.asked }
    }
  }

  func pause(_ seconds: Double) {
    var interval = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - Double(Int(seconds))) * 1e9))
    nanosleep(&interval, nil)
  }
#endif
