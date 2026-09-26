#if os(Linux)
  import CLinuxUI
  import DriftboxCanvas
  import DriftboxGPU
  import DriftboxGPUGLES
  import DriftboxHost
  import DriftboxScenes
  import DriftboxText
  import DriftboxTextLinux
  import Foundation
  import Glibc

  @MainActor
  private final class Drawing {
    let device: GLESDevice
    let typesetter = PangoTypesetter()
    let scene: any GPUScene
    let canvas: Canvas
    let presenter: Presenter
    var target: (any GPUTarget)?

    init(device: GLESDevice) throws {
      self.device = device
      scene = try GraphicLabScene(device: device, typesetter: typesetter)
      canvas = try Canvas(device: device, typesetter: typesetter)
      presenter = try Presenter(device: device)
    }

    func draw(state: WindowState, framebuffer: UInt32, width: Int, height: Int, scale: Float) throws {
      if target?.width != width || target?.height != height {
        target = try device.makeTarget(width: width, height: height)
        print("drawable: \(width) × \(height), scale \(scale)")
      }
      guard let target else { return }
      let elapsed = state.elapsed
      let pulse = Float((sin(elapsed * 3) + 1) * 0.3)
      scene.draw(
        SceneInput(
          time: elapsed, touch: state.touch, running: state.running, bpm: 120,
          scoreBeat: elapsed * 2, levels: (pulse, 0.2, 0.1), wideLevels: (pulse, 0.1),
          bands: [Float](repeating: pulse, count: 16), pixelRatio: scale), into: target, on: device)
      try canvas.begin(width: width, height: height)
      canvas.scale(scale, scale)
      canvas.fill = Colour(0x101820, alpha: 0.92)
      canvas.fillRect(0, 0, Float(width) / scale, 104)
      canvas.font = FontRequest(families: ["DejaVu Sans", "sans-serif"], weight: 700, size: 19)
      canvas.fill = Colour(0xffffff)
      canvas.fillText("Driftbox · Linux", 24, 32)
      canvas.font = FontRequest(families: ["DejaVu Sans"], size: 14)
      canvas.fillText("Drag to explore · Space to pause · Esc to close", 24, 57)
      canvas.fillText(
        state.actorReady
          ? "Async work resumed on MainActor · café · العربية" : "Checking Swift async integration…", 24, 82)
      presenter.overlay(canvas.finish(), into: target, on: device)
      try device.presentToToolkit(target, framebuffer: framebuffer, width: width, height: height)
    }
  }

  @MainActor
  private final class WindowState {
    var window: OpaquePointer?
    var drawing: Drawing?
    var failure: Error?
    var actorReady = false
    var frames = 0
    var lifecycleReady = false
    var pointerEvents = 0
    var pauseEvents = 0
    var running = true
    var touch: SIMD2<Float>?
    var logicalWidth: Float = 1
    var logicalHeight: Float = 1
    var elapsed = 0.0
    var last = HostTime.now()

    func render(width: Int, height: Int, scale: Int) {
      do {
        // Capture GTK's framebuffer before scene/canvas initialization can bind another one.
        let device = try drawing?.device ?? GLESDevice(borrowingCurrentContext: ())
        let drawable = device.beginToolkitFrame()
        if drawing == nil {
          print("GTK GLES: \(device.renderer)")
          drawing = try Drawing(device: device)
        }
        logicalWidth = Float(max(1, width))
        logicalHeight = Float(max(1, height))
        let now = HostTime.now()
        if running { elapsed += min(0.1, HostTime.seconds(from: last, to: now)) }
        last = now
        guard drawable.width > 0, drawable.height > 0 else { return }
        try drawing?.draw(
          state: self, framebuffer: drawable.framebuffer, width: drawable.width,
          height: drawable.height, scale: Float(drawable.width) / logicalWidth)
        frames += 1
      } catch {
        failure = error
        if let window { db_window_close(window) }
      }
    }
  }

  private func rendered(context: UnsafeMutableRawPointer?, width: Int32, height: Int32, scale: Int32) {
    guard let context else { return }
    let state = Unmanaged<WindowState>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
      state.render(
        width: Int(width), height: Int(height), scale: Int(scale))
    }
  }
  private func event(context: UnsafeMutableRawPointer?, kind: Int32, x: Double, y: Double) {
    guard let context else { return }
    let state = Unmanaged<WindowState>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
      switch kind {
      case 1:
        state.pointerEvents += 1
        state.touch = SIMD2(
          max(0, min(1, Float(x) / state.logicalWidth)), max(0, min(1, 1 - Float(y) / state.logicalHeight)))
      case 2, 4: state.touch = nil
      case 3:
        state.running.toggle()
        state.pauseEvents += 1
        if let window = state.window {
          db_window_title(window, state.running ? "Driftbox · Linux window experiment" : "Driftbox · Paused")
        }
      default: break
      }
    }
  }
  private func cleaned(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let state = Unmanaged<WindowState>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
      // GTK has made the context current and has not destroyed it yet.
      state.drawing = nil
    }
  }

  @main
  struct LinuxWindow {
    @MainActor static func main() {
      do { try run() } catch {
        FileHandle.standardError.write(Data("driftbox-linux-window: \(error)\n".utf8))
        exit(1)
      }
    }
    @MainActor static func run() throws {
      let args = Array(CommandLine.arguments.dropFirst())
      var seconds: Double?
      let selfTest = args == ["--self-test"]
      if selfTest {
        seconds = 6
      } else if !args.isEmpty {
        guard args.count == 2, args[0] == "--seconds", let value = Double(args[1]), value.isFinite,
          value >= 1, value <= 3600
        else { throw GPUError("usage: driftbox-linux-window [--seconds 1...3600 | --self-test]") }
        seconds = value
      }
      let state = WindowState()
      var error = [CChar](repeating: 0, count: 512)
      guard
        let window = db_window_new(
          Unmanaged.passUnretained(state).toOpaque(), rendered, event, cleaned, &error, error.count)
      else {
        throw GPUError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      state.window = window
      defer {
        db_window_free(window)
        state.window = nil
      }
      let probe = Task { @MainActor [weak state] in
        try await Task.sleep(for: .milliseconds(200))
        let result = await Task.detached { "background completion" }.value
        MainActor.preconditionIsolated()
        guard let state else { return }
        state.actorReady = result == "background completion"
        print("MainActor: delayed task and background completion resumed on the GTK thread")
      }
      let lifecycle = Task { @MainActor [weak state] in
        guard selfTest else { return }
        try await Task.sleep(for: .seconds(1))
        guard let state, let window = state.window else { return }
        db_window_resize(window, 800, 600)
        try await Task.sleep(for: .seconds(1))
        let resized = state.logicalWidth == 800 && state.logicalHeight == 600
        db_window_visible(window, 0)
        try await Task.sleep(for: .milliseconds(250))
        let hiddenFrames = state.frames
        try await Task.sleep(for: .milliseconds(500))
        MainActor.preconditionIsolated()
        let stopped = state.frames == hiddenFrames
        print(
          "lifecycle: resize=\(resized), hidden rendering stopped=\(stopped), MainActor resumed while hidden")
        db_window_visible(window, 1)
        try await Task.sleep(for: .seconds(1))
        state.lifecycleReady = resized && stopped && state.frames > hiddenFrames
      }
      let closer = Task { @MainActor [weak state] in
        guard let seconds else { return }
        try await Task.sleep(for: .seconds(seconds))
        if let window = state?.window { db_window_close(window) }
      }
      defer {
        lifecycle.cancel()
        probe.cancel()
        closer.cancel()
      }
      db_window_run(window)
      if let failure = state.failure { throw failure }
      let toolkitError = String(cString: db_window_error(window))
      guard toolkitError.isEmpty else { throw GPUError(toolkitError) }
      if seconds != nil {
        guard state.actorReady, state.frames > 1 else {
          throw GPUError("window/async probe did not complete")
        }
      }
      if selfTest && !state.lifecycleReady { throw GPUError("window lifecycle probe did not complete") }
      print("input: \(state.pointerEvents) pointer events, \(state.pauseEvents) pause toggles")
      print(
        "closed cleanly after \(state.frames) frames; MainActor probe: \(state.actorReady ? "passed" : "not completed")"
      )
    }
  }
#else
  @main struct LinuxWindow { static func main() { print("Run this experiment inside Linux.") } }
#endif
