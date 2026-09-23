#if canImport(AVFoundation)
  import AppKit
  import AVFoundation
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxGPU
  import DriftboxGPUMetal
  import DriftboxHost
  import DriftboxScenes
  import Foundation
  import ImageIO
  import QuartzCore
  import UniformTypeIdentifiers

  /// Somewhere for an instantiation callback to leave what it made.
  final class Made: @unchecked Sendable {
    var unit: AVAudioUnit?
  }

  /// Plays a song through the speakers: the engine as an Audio Unit, hosted in an AVAudioEngine.
  ///
  ///     swift run -c release driftbox-play conformance/fixtures/documents/acid.song.json
  ///     swift run -c release driftbox-play song.json --seconds 20 --start-bar 8
  /// The loudest sample seen since last asked, from the audio thread's tap.
  final class Peak: @unchecked Sendable {
    private var value: Float = 0
    private let lock = NSLock()
    func note(_ sample: Float) {
      lock.withLock { value = max(value, sample) }
    }
    func take() -> Float {
      lock.withLock {
        defer { value = 0 }
        return value
      }
    }
  }

  @main
  struct Play {
    static func main() throws {
      var arguments = Array(CommandLine.arguments.dropFirst())
      func option(_ name: String) -> Double? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return Double(arguments[index + 1])
      }
      let seconds = option("--seconds")
      let startBar = option("--start-bar") ?? 0
      // --bench: no audio device; run the engine as fast as it goes and say how fast that is.
      let bench = arguments.firstIndex(of: "--bench").map { arguments.remove(at: $0) } != nil
      // --window: Pulse too, through the GPU layer on Metal, in a window of its own.
      let windowed = arguments.firstIndex(of: "--window").map { arguments.remove(at: $0) } != nil
      guard arguments.count == 1 else {
        FileHandle.standardError.write(
          Data("usage: driftbox-play <song.json> [--seconds s] [--start-bar n] [--bench] [--window]\n".utf8))
        exit(64)
      }
      let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
      guard let song = SongCodec.decode(text) else {
        FileHandle.standardError.write(Data("\(arguments[0]) is not a song\n".utf8))
        exit(65)
      }

      if bench {
        runBench(song, named: arguments[0])
        return
      }

      AUAudioUnit.registerSubclass(
        DriftboxAudioUnit.self, as: DriftboxAudioUnit.componentDescription, name: "Driftbox", version: 1)
      let audio = AVAudioEngine()
      let made = Made()
      let group = DispatchGroup()
      group.enter()
      AVAudioUnit.instantiate(with: DriftboxAudioUnit.componentDescription, options: []) { unit, error in
        if let error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
        made.unit = unit
        group.leave()
      }
      group.wait()
      guard let unit = made.unit, let driftbox = unit.auAudioUnit as? DriftboxAudioUnit else { exit(70) }

      audio.attach(unit)
      audio.connect(unit, to: audio.mainMixerNode, format: unit.outputFormat(forBus: 0))
      driftbox.load(song)
      if startBar > 0 {
        let plan = song.plan(bars: Int(startBar))
        if let last = plan.last {
          driftbox.send(
            .seek(songFrame: Int((last.time + last.stepSeconds) * unit.outputFormat(forBus: 0).sampleRate)))
        }
      }
      driftbox.send(.play)

      // What reaches the output, once a second: proof of life for a run nobody is listening to.
      let peak = Peak()
      // Called on an audio queue, so it must not inherit `main`'s actor.
      let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        var loudest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
          loudest = max(loudest, abs(data[0][frame]), abs(data[1][frame]))
        }
        peak.note(loudest)
      }
      audio.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
      try audio.start()

      let length = SongRenderer.seconds(of: song)
      print(
        String(
          format: "playing %@ (%.0f seconds a pass) at %.0f Hz", arguments[0], length,
          unit.outputFormat(forBus: 0).sampleRate))
      let until = seconds.map { Date().addingTimeInterval($0) }
      if windowed, let host = driftbox.host {
        let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
        try MainActor.assumeIsolated {
          try watch(
            host, bpm: song.bpm, title: "Driftbox — \(SongFile.name(fromFileName: name))", until: until,
            report: { report(driftbox, peak) })
        }
        audio.stop()
        return
      }
      if until == nil { print("ctrl-c to stop") }
      while until.map({ Date() < $0 }) ?? true {
        Thread.sleep(forTimeInterval: 1)
        report(driftbox, peak)
      }
      audio.stop()
    }

    /// What reaches the output, and what making it costs: proof of life, once a second.
    static func report(_ driftbox: DriftboxAudioUnit, _ peak: Peak) {
      let load = driftbox.host?.takeLoad() ?? (fraction: 0, longestMilliseconds: 0, calls: 0)
      print(
        String(
          format:
            "  peak %.3f  song frame %d  render %.1f%% of the audio's time, longest call %.2fms, %d calls",
          peak.take(), driftbox.host?.songFrame.load(ordering: .relaxed) ?? -1, load.fraction * 100,
          load.longestMilliseconds, load.calls))
    }

    /// The song, seen, as on Windows: Pulse in a window, from what the engine reports having
    /// played, drawn through the GPU layer on Metal once per refresh of the display — taking the
    /// layer's next drawable waits for one, which is what paces the loop — until the window is
    /// closed or the time is up.
    @MainActor
    static func watch(
      _ host: EngineHost, bpm: Double, title: String, until: Date?, report: () -> Void
    ) throws {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      app.finishLaunching()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = title
      window.isReleasedWhenClosed = false
      let layer = CAMetalLayer()
      let view = NSView()
      view.wantsLayer = true
      view.layer = layer
      window.contentView = view
      window.center()
      window.makeKeyAndOrderFront(nil)
      app.activate()

      func pixels() -> (width: Int, height: Int) {
        let size = view.convertToBacking(view.bounds.size)
        layer.contentsScale = window.backingScaleFactor
        return (max(1, Int(size.width)), max(1, Int(size.height)))
      }
      let device = try MetalDevice()
      var size = pixels()
      let surface = try device.makeSurface(layer: layer, width: size.width, height: size.height)
      let scene = try PulseScene(device: device)
      let presenter = try Presenter(device: device)
      var frame = try device.makeTarget(width: size.width, height: size.height)

      // As the scene tests do: with DRIFTBOX_SCENE_SHOTS set to a directory, each second's frame
      // is written there as it was presented, for looking at a run nobody watched.
      let shots = ProcessInfo.processInfo.environment["DRIFTBOX_SCENE_SHOTS"]
      var shot = 0
      let began = HostTime.now()
      var reported = began
      var events: [EngineEvent] = []
      while window.isVisible, until.map({ Date() < $0 }) ?? true {
        while let event = app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        {
          app.sendEvent(event)
        }
        let now = pixels()
        if now != size {
          size = now
          try surface.resize(width: size.width, height: size.height)
          frame = try device.makeTarget(width: size.width, height: size.height)
        }
        events.removeAll(keepingCapacity: true)
        while let event = host.nextEvent() { events.append(event) }
        host.collect()
        let input = SceneInput(
          time: HostTime.seconds(from: began, to: HostTime.now()),
          peakLeft: Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          peakRight: Float(bitPattern: host.peakRight.load(ordering: .relaxed)), events: events,
          running: host.playing.load(ordering: .relaxed), bpm: bpm,
          pixelRatio: Float(window.backingScaleFactor))
        scene.draw(input, into: frame, on: device)
        let target = try surface.target()
        presenter.present(frame, into: target, on: device)
        let second = HostTime.seconds(from: reported, to: HostTime.now()) >= 1
        if second, let shots {
          shot += 1
          try png(try device.readPixels(target), width: target.width, height: target.height)
            .write(to: URL(fileURLWithPath: shots).appendingPathComponent("pulse-\(shot).png"))
        }
        try surface.present()
        if second {
          reported = HostTime.now()
          report()
        }
      }
      window.close()
    }

    /// BGRA pixels, rows from the top, as a PNG.
    static func png(_ pixels: [UInt8], width: Int, height: Int) throws -> Data {
      let data = NSMutableData()
      guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { throw GPUError("could not make a PNG") }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw GPUError("could not write a PNG") }
      return data as Data
    }
  }
#elseif os(Windows)
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxGPU
  import DriftboxGPUD3D11
  import DriftboxHost
  import DriftboxHostWindows
  import DriftboxScenes
  import DriftboxWin32
  import Foundation

  /// Plays a song through the speakers: the engine rendered by a WASAPI stream, through the
  /// platform-neutral `AudioRouting`. Everything below the route is the same on every platform;
  /// once the Mac's route is one too, this is the whole of the player and the branch above goes.
  ///
  ///     driftbox-play conformance/fixtures/documents/acid.song.json --seconds 20 --start-bar 8
  ///     driftbox-play conformance/fixtures/documents/acid.song.json --window
  ///
  /// `--window` shows it too: Pulse, drawn through the GPU layer on Direct3D, in a window of its own.
  @main
  struct Play {
    @MainActor
    static func main() throws {
      var arguments = Array(CommandLine.arguments.dropFirst())
      func option(_ name: String) -> Double? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return Double(arguments[index + 1])
      }
      let seconds = option("--seconds")
      let startBar = option("--start-bar") ?? 0
      let bench = arguments.firstIndex(of: "--bench").map { arguments.remove(at: $0) } != nil
      let windowed = arguments.firstIndex(of: "--window").map { arguments.remove(at: $0) } != nil
      guard arguments.count == 1 else {
        FileHandle.standardError.write(
          Data("usage: driftbox-play <song.json> [--seconds s] [--start-bar n] [--bench] [--window]\n".utf8))
        exit(64)
      }
      let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
      guard let song = SongCodec.decode(text) else {
        FileHandle.standardError.write(Data("\(arguments[0]) is not a song\n".utf8))
        exit(65)
      }

      if bench {
        runBench(song, named: arguments[0])
        return
      }

      let route = WASAPIRoute()
      route.onChange = { [unowned route] in
        print(
          route.current.map { "  playing through \($0.name)" } ?? "  no sound: \(route.error ?? "no device")")
      }
      let host = EngineHost(sampleRate: route.sampleRate)
      host.load(song)
      if startBar > 0, let last = song.plan(bars: Int(startBar)).last {
        host.send(.seek(songFrame: Int((last.time + last.stepSeconds) * route.sampleRate)))
      }
      host.send(.play)
      route.attach(host.renderSource)
      route.onChange?()

      print(
        String(
          format: "playing %@ (%.0f seconds a pass) at %.0f Hz, %.1fms from render to speaker", arguments[0],
          SongRenderer.seconds(of: song), route.sampleRate, route.latency * 1000))
      let until = seconds.map { Date().addingTimeInterval($0) }
      if windowed {
        let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
        try watch(host, bpm: song.bpm, title: "Driftbox — \(SongFile.name(fromFileName: name))", until: until)
      } else {
        if until == nil { print("ctrl-c to stop") }
        while until.map({ Date() < $0 }) ?? true {
          // The main run loop rather than a sleep: word of a device change arrives on it.
          RunLoop.main.run(until: Date().addingTimeInterval(1))
          report(host)
        }
      }
      route.detach(host.renderSource.context)
    }

    /// What reaches the output, and what making it costs: proof of life, once a second.
    static func report(_ host: EngineHost) {
      let load = host.takeLoad()
      let peak = max(
        Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
        Float(bitPattern: host.peakRight.load(ordering: .relaxed)))
      print(
        String(
          format:
            "  peak %.3f  song frame %d  render %.1f%% of the audio's time, longest call %.2fms, %d calls",
          peak, host.songFrame.load(ordering: .relaxed), load.fraction * 100, load.longestMilliseconds,
          load.calls))
    }

    /// BGRA pixels, rows from the top, as a 32-bit BMP: the one image format that needs nothing
    /// but its own header, which is all a frame kept for looking at wants.
    static func bitmap(_ pixels: [UInt8], width: Int, height: Int) -> Data {
      var data = Data()
      func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
      }
      data.append(contentsOf: Array("BM".utf8))
      put(UInt32(54 + pixels.count))
      put(UInt32(0))
      put(UInt32(54))
      put(UInt32(40))
      put(Int32(width))
      put(Int32(-height))  // negative: rows from the top, as the pixels are
      put(UInt16(1))
      put(UInt16(32))
      for _ in 0..<6 { put(UInt32(0)) }
      data.append(contentsOf: pixels)
      return data
    }

    /// The song, seen: Pulse in a window, from what the engine reports having played, drawn once
    /// per refresh of the display — presenting waits for it, which is what paces the loop — until
    /// the window is closed or the time is up.
    @MainActor
    static func watch(_ host: EngineHost, bpm: Double, title: String, until: Date?) throws {
      let window = try Win32Window(title: title, width: 960, height: 540)
      let device = try D3D11Device()
      let surface = try device.makeSurface(window: window.handle, width: window.width, height: window.height)
      let scene = try PulseScene(device: device)
      let presenter = try Presenter(device: device)
      var frame = try device.makeTarget(width: window.width, height: window.height)
      var resized: (width: Int, height: Int)?
      window.onResize = { resized = ($0, $1) }

      // As the scene tests do on the Mac: with DRIFTBOX_SCENE_SHOTS set to a directory, each
      // second's frame is written there as it was presented, for looking at a run nobody watched.
      let shots = ProcessInfo.processInfo.environment["DRIFTBOX_SCENE_SHOTS"]
      var shot = 0
      let began = HostTime.now()
      var reported = began
      var events: [EngineEvent] = []
      while window.pump(), until.map({ Date() < $0 }) ?? true {
        if let size = resized {
          resized = nil
          try surface.resize(width: size.width, height: size.height)
          frame = try device.makeTarget(width: size.width, height: size.height)
        }
        events.removeAll(keepingCapacity: true)
        while let event = host.nextEvent() { events.append(event) }
        host.collect()
        let input = SceneInput(
          time: HostTime.seconds(from: began, to: HostTime.now()),
          peakLeft: Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          peakRight: Float(bitPattern: host.peakRight.load(ordering: .relaxed)), events: events,
          running: host.playing.load(ordering: .relaxed), bpm: bpm, pixelRatio: 1)
        scene.draw(input, into: frame, on: device)
        let target = try surface.target()
        presenter.present(frame, into: target, on: device)
        let second = HostTime.seconds(from: reported, to: HostTime.now()) >= 1
        if second, let shots {
          shot += 1
          try bitmap(try device.readPixels(target), width: target.width, height: target.height)
            .write(to: URL(fileURLWithPath: shots).appendingPathComponent("pulse-\(shot).bmp"))
        }
        try surface.present()
        // Word of a device change, which the audio route hops to the main queue with.
        RunLoop.main.run(mode: .default, before: Date())
        if second {
          reported = HostTime.now()
          report(host)
        }
      }
    }
  }
#elseif os(Android)
  import Android
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import DriftboxHostAndroid
  import FoundationEssentials
  import Synchronization

  /// Raised from AAudio's thread when the stream's device goes away, and seen by the loop below,
  /// which is this program's main actor: a phone has no run loop until there is an app.
  final class Flag: Sendable {
    private let raised = Atomic<Bool>(false)
    func raise() { raised.store(true, ordering: .releasing) }
    func take() -> Bool { raised.exchange(false, ordering: .acquiringAndReleasing) }
  }

  /// Plays a song through the phone: the engine rendered by an AAudio stream, through the
  /// platform-neutral `AudioRouting`, as on Windows. Only the essentials of Foundation, which is
  /// what lets it link on Android without the rest.
  ///
  ///     driftbox-play song.json --seconds 20 --start-bar 8
  @main
  struct Play {
    @MainActor
    static func main() throws {
      var arguments = Array(CommandLine.arguments.dropFirst())
      func option(_ name: String) -> Double? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return Double(arguments[index + 1])
      }
      let seconds = option("--seconds")
      let startBar = option("--start-bar") ?? 0
      let bench = arguments.firstIndex(of: "--bench").map { arguments.remove(at: $0) } != nil
      guard arguments.count == 1 else {
        print("usage: driftbox-play <song.json> [--seconds s] [--start-bar n] [--bench]")
        exit(64)
      }
      let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
      guard let song = SongCodec.decode(text) else {
        print("\(arguments[0]) is not a song")
        exit(65)
      }

      if bench {
        runBench(song, named: arguments[0])
        return
      }

      let lost = Flag()
      let route = AAudioRoute(hop: { _ in lost.raise() })
      route.onChange = { [unowned route] in
        print(
          route.current.map { "  playing through \($0.name): \(route.details ?? "")" }
            ?? "  no sound: \(route.error ?? "no device")")
      }
      let host = EngineHost(sampleRate: route.sampleRate)
      host.load(song)
      if startBar > 0, let last = song.plan(bars: Int(startBar)).last {
        host.send(.seek(songFrame: Int((last.time + last.stepSeconds) * route.sampleRate)))
      }
      host.send(.play)
      route.attach(host.renderSource)
      route.onChange?()

      print("playing \(arguments[0]) (\(Int(SongRenderer.seconds(of: song))) seconds a pass)")
      if seconds == nil { print("ctrl-c to stop") }
      var elapsed = 0.0
      var xruns = route.xruns
      while seconds.map({ elapsed < $0 }) ?? true {
        var second = timespec(tv_sec: 1, tv_nsec: 0)
        nanosleep(&second, nil)
        elapsed += 1
        if lost.take() { route.apply() }
        route.tune()
        let load = host.takeLoad()
        let peak = max(
          Float(bitPattern: host.peakLeft.load(ordering: .relaxed)),
          Float(bitPattern: host.peakRight.load(ordering: .relaxed)))
        let now = route.xruns
        print(
          "  peak \(fixed(Double(peak), 3))  song frame \(host.songFrame.load(ordering: .relaxed))"
            + "  render \(fixed(load.fraction * 100, 1))% of the audio's time,"
            + " longest call \(fixed(load.longestMilliseconds, 2))ms, \(load.calls) calls,"
            + " \(now - xruns) underruns, \(fixed(route.latency * 1000, 1))ms to the speaker")
        xruns = now
      }
      route.detach(host.renderSource.context)
    }
  }
#else
  import DriftboxDocument
  #if canImport(FoundationEssentials)
    import FoundationEssentials
  #else
    import Foundation
  #endif
  #if canImport(Glibc)
    import Glibc
  #endif

  /// No player here yet — Linux has no route behind the ports — but the bench needs no device.
  ///
  ///     driftbox-play song.json --bench
  @main
  struct Play {
    static func main() throws {
      var arguments = Array(CommandLine.arguments.dropFirst())
      guard let flag = arguments.firstIndex(of: "--bench"), arguments.count == 2 else {
        print("driftbox-play only benches here, with no device: driftbox-play <song.json> --bench")
        exit(64)
      }
      arguments.remove(at: flag)
      let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
      guard let song = SongCodec.decode(text) else {
        print("\(arguments[0]) is not a song")
        exit(65)
      }
      runBench(song, named: arguments[0])
    }
  }
#endif
