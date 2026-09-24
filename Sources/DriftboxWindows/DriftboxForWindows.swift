#if os(Windows)
  import DriftboxDesktop
  import DriftboxGPUD3D11
  import DriftboxHost
  import DriftboxHostWindows
  import DriftboxSession
  import DriftboxTextWindows
  import DriftboxWin32
  import Foundation

  /// Driftbox on Windows: the one place that chooses Windows' parts — WASAPI and WinMM for the
  /// sound and the cables, a Win32 window, Direct3D to draw in it, DirectWrite for type — and hands
  /// them to the same app every desktop platform runs. Everything else is `Desktop` and `Session`.
  ///
  /// Word from another thread — a device come or gone, a note on a cable — reaches the interface
  /// through the window's own loop, which is the only one that turns while it runs.
  @main
  struct DriftboxForWindows {
    @MainActor
    static func main() throws {
      let window = try Win32Window(title: "Driftbox", width: 1280, height: 720)
      let hop: @Sendable (@escaping @Sendable () -> Void) -> Void = { [mailbox = window] work in
        mailbox.post(work)
      }
      let route = WASAPIRoute(hop: hop)
      let session = Session(
        host: EngineHost(sampleRate: route.sampleRate), audio: route, midiIn: WinMMInput(),
        midiOut: WinMMOutput(), memory: .standard, hop: hop)
      // Stopped at the top, as it was last saved: sound nobody asked for is not worth restoring.
      session.restore()

      let device = try D3D11Device()
      let surface = try device.makeSurface(window: window.handle, width: window.width, height: window.height)
      let desktop = try Desktop(
        session: session, window: window, device: device, surface: surface,
        typesetter: try DirectWriteTypesetter())
      try desktop.run()
    }
  }
#else
  /// Driftbox for Windows is for Windows; the Mac has its own app, and Android its own.
  @main
  struct DriftboxForWindows {
    static func main() {
      print("Driftbox for Windows runs on Windows.")
    }
  }
#endif
