#if os(Linux)
  import DriftboxDesktop
  import DriftboxGTK
  import DriftboxHost
  import DriftboxHostLinux
  import DriftboxRackSession
  import DriftboxSession
  import DriftboxTextLinux
  import Foundation
  import Glibc

  @main struct DriftboxLinux {
    @MainActor static func main() {
      do { try run() } catch {
        FileHandle.standardError.write(Data("driftbox-linux: \(error)\n".utf8))
        exit(1)
      }
    }
    @MainActor static func run() throws {
      var smoke = false
      var silent = false
      var path: String?
      for argument in CommandLine.arguments.dropFirst() {
        switch argument {
        case "--smoke-test": smoke = true
        case "--silent": silent = true
        default:
          guard !argument.hasPrefix("-"), path == nil else {
            throw PipeWireError("usage: driftbox-linux [--silent] [--smoke-test] [song]")
          }
          path = argument
        }
      }
      let window = try GTKWindow()
      let route = silent ? nil : PipeWireRoute()
      let midi: ALSAMIDI?
      do { midi = try ALSAMIDI() } catch {
        midi = nil
        FileHandle.standardError.write(Data("MIDI unavailable: \(error)\n".utf8))
      }
      defer {
        midi?.stop()
        route?.stop()
        window.dispose()
      }
      let memory = smoke ? nil : UserDefaults(suiteName: "org.driftbox.linux")
      let session = Session(
        host: EngineHost(sampleRate: route?.sampleRate ?? 48000), audio: route, midiIn: midi, midiOut: midi,
        memory: memory,
        hop: { work in window.post(work) })
      if let path {
        session.open(file: URL(fileURLWithPath: path))
      } else {
        session.restore()
        if session.song == nil, let entry = session.entries.first(where: { $0.id == "acid" }) {
          session.open(entry)
          session.stop()
        }
      }
      if smoke { session.stop() }
      let rack = RackSession(sampleRate: route?.sampleRate ?? 48000, audio: route, memory: memory)
      var desktop: Desktop? = try Desktop(
        session: session, window: window, device: window.device,
        surface: window.surface, typesetter: PangoTypesetter(), rack: rack)
      defer {
        window.makeCurrent()
        desktop = nil
        session.close()
        rack.close()
      }
      print("Linux desktop: \(window.device.renderer)")
      if let error = route?.error { print("Audio unavailable: \(error)") }
      var played = false
      var rackAt: Int?
      let probe = Task { @MainActor in
        guard smoke else { return }
        try await Task.sleep(for: .seconds(1))
        session.play()
        try await Task.sleep(for: .seconds(4))
        played = session.isPlaying
        session.stop()
        window.onEvent?(.command(DesktopMenus.showRack))
        rackAt = window.frames
        try await Task.sleep(for: .seconds(1))
        window.close()
      }
      defer { probe.cancel() }
      try desktop!.run()
      if smoke {
        guard session.song != nil, desktop?.showsRack == true,
          window.frames > (rackAt ?? window.frames) + 2,
          silent || (played && (route?.renderedFrames ?? 0) > 48000),
          route?.error == nil
        else {
          throw PipeWireError(
            "desktop smoke test failed: frames=\(window.frames), audio=\(route?.renderedFrames ?? 0), error=\(route?.error ?? "none")"
          )
        }
      }
      print("closed: \(window.frames) GUI frames, \(route?.renderedFrames ?? 0) audio frames")
    }
  }
#else
  @main struct DriftboxLinux { static func main() { print("Run Driftbox Linux inside Linux.") } }
#endif
