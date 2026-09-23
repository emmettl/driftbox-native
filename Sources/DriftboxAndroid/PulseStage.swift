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
  import Synchronization

  /// A song, played and seen: the engine through AAudio, and Pulse drawn from what it played on
  /// the phone's screen, as `driftbox-play --window` does on Windows and the Mac, with the whole
  /// screen a pad for the performance filter.
  ///
  /// Two threads. Java's main thread, which calls in, owns the engine's commands and the audio route,
  /// both of which are the main actor's; and a render thread of the `Renderer`'s own owns everything
  /// OpenGL, since a context is current on one thread, and reads the engine's events.
  @MainActor
  final class PulseStage {
    private let host: EngineHost
    private let route: AAudioRoute
    private let lost = Flag()
    private let renderer: Renderer

    init?(json: String) {
      guard let song = SongCodec.decode(json) else { return nil }
      host = EngineHost(sampleRate: 48000)
      route = AAudioRoute(hop: { [lost] _ in lost.raise() })
      host.load(song)
      host.send(.play)
      route.attach(host.renderSource)
      renderer = Renderer(host: host, bpm: song.bpm)
    }

    /// Stop drawing and playing, and wait until both have.
    func stop() {
      renderer.stop()
      route.detach(host.renderSource.context)
    }

    /// The app in view, or out of it. Out of it, Android keeps it to the little cores, so the song
    /// stops where it is, the audio stream is let go of, and nothing is drawn; back in view, all
    /// three start again.
    func setShown(_ shown: Bool) {
      if shown {
        route.resume()
        host.send(.play)
      } else {
        host.send(.stop)
        route.suspend()
      }
      renderer.paused.store(!shown, ordering: .releasing)
    }

    func show(window: OpaquePointer, width: Int, height: Int) {
      renderer.change(to: Renderer.Window(handle: window, width: width, height: height))
    }

    func hide() {
      renderer.change(to: nil)
    }

    /// A finger at `x, y`, 0...1 from the bottom left, or lifted: the performance filter's pad, and
    /// Pulse drawing the finger where it is.
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

  /// The render thread: an OpenGL ES device, Pulse, and the window it draws in when there is one.
  final class Renderer: @unchecked Sendable {
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
    private let bpm: Double
    private let changes = Mutex(Change())
    private let running = Atomic<Bool>(true)
    /// Set while the app is out of view: a window kept, but nothing drawn in it.
    let paused = Atomic<Bool>(false)
    private let frames = Atomic<Int>(0)
    private let said = Mutex("starting")
    let touch = Mutex<SIMD2<Float>?>(nil)
    private var thread = pthread_t()

    init(host: EngineHost, bpm: Double) {
      self.host = host
      self.bpm = bpm
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
      let scene: PulseScene
      let presenter: Presenter
      do {
        device = try GLESDevice()
        scene = try PulseScene(device: device)
        presenter = try Presenter(device: device)
      } catch {
        said.withLock { $0 = "no GPU: \(error)" }
        drainChanges()
        return
      }
      var surface: (any GPUSurface)?
      var frame: (any GPUTarget)?
      var seen = 0
      let began = HostTime.now()
      var events: [EngineEvent] = []
      while running.load(ordering: .acquiring) {
        let (window, ticket) = changes.withLock { ($0.window, $0.asked) }
        if ticket != seen {
          surface = nil
          frame = nil
          if let window {
            do {
              surface = try device.makeSurface(
                window: window.handle, width: window.width, height: window.height)
              frame = try device.makeTarget(width: window.width, height: window.height)
              said.withLock { $0 = "drawing \(window.width) by \(window.height) on \(device.renderer)" }
            } catch {
              surface = nil
              said.withLock { $0 = "no surface: \(error)" }
            }
          } else {
            said.withLock { $0 = "with no window" }
          }
          seen = ticket
          changes.withLock { $0.done = ticket }
        }
        guard let surface, let frame, !paused.load(ordering: .acquiring) else {
          pause(0.01)
          continue
        }
        events.removeAll(keepingCapacity: true)
        while let event = host.nextEvent() { events.append(event) }
        let input = SceneInput(
          time: HostTime.seconds(from: began, to: HostTime.now()),
          peakLeft: Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          peakRight: Float(bitPattern: host.peakRight.load(ordering: .relaxed)), events: events,
          touch: touch.withLock { $0 }, running: host.playing.load(ordering: .relaxed), bpm: bpm)
        scene.draw(input, into: frame, on: device)
        do {
          presenter.present(frame, into: try surface.target(), on: device)
          try surface.present()
          frames.add(1, ordering: .relaxed)
        } catch {
          said.withLock { $0 = "could not show a frame: \(error)" }
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
