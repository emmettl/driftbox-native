#if os(Windows)
  import DriftboxDesktop
  import DriftboxGPUD3D11
  import DriftboxHost
  import DriftboxHostVST3
  import DriftboxHostWindows
  import DriftboxRackSession
  import DriftboxSession
  import DriftboxTextWindows
  import DriftboxWin32
  import Foundation
  import WinSDK

  /// Driftbox on Windows: the one place that chooses Windows' parts — WASAPI and WinMM for the
  /// sound and the cables, a Win32 window, Direct3D to draw in it, DirectWrite for type — and hands
  /// them to the same app every desktop platform runs. Everything else is `Desktop` and `Session`.
  ///
  /// Word from another thread — a device come or gone, a note on a cable — reaches the interface
  /// through the window's own loop, which is the only one that turns while it runs.
  ///
  ///     DriftboxWindows.exe                  the song it was left on, stopped at the top
  ///     DriftboxWindows.exe song.driftbox    that song, as a double-click in Explorer opens it
  ///     DriftboxWindows.exe --register       make .driftbox files open here, for this user
  ///     DriftboxWindows.exe --unregister     and give them back
  @main
  struct DriftboxForWindows {
    /// Songs, as Explorer knows them once they are registered.
    static let songs = Win32FileType(
      fileExtension: ".driftbox", progID: "Driftbox.Song", name: "Driftbox Song")

    @MainActor
    static func main() throws {
      let arguments = CommandLine.arguments.dropFirst()
      switch arguments.first {
      case "--register":
        try songs.register(executable: executable())
        print("\(songs.fileExtension) files open in Driftbox.")
        return
      case "--unregister":
        songs.unregister()
        print("\(songs.fileExtension) files are no longer Driftbox's.")
        return
      default:
        break
      }

      let window = try Win32Window(title: "Driftbox", width: 1280, height: 720)
      let hop: @Sendable (@escaping @Sendable () -> Void) -> Void = { [mailbox = window] work in
        mailbox.post(work)
      }
      let route = WASAPIRoute(hop: hop)
      let session = Session(
        host: EngineHost(sampleRate: route.sampleRate), audio: route, midiIn: WinMMInput(),
        midiOut: WinMMOutput(), memory: UserDefaults.standard, hop: hop)
      if let path = arguments.first {
        // A song handed over, as Explorer hands one to the program it opens with.
        session.open(file: URL(fileURLWithPath: path))
      } else {
        // Stopped at the top, as it was last saved: sound nobody asked for is not worth restoring.
        session.restore()
      }

      let device = try D3D11Device()
      let surface = try device.makeSurface(window: window.handle, width: window.width, height: window.height)
      let desktop = try Desktop(
        session: session, window: window, device: device, surface: surface,
        typesetter: try DirectWriteTypesetter(),
        // The rack, through the same output: heard beside the groovebox, and shown in its place;
        // its plug-ins VST 3.
        rack: RackSession(
          sampleRate: route.sampleRate, audio: route, plugins: VST3Hosting(), memory: UserDefaults.standard))
      try desktop.run()
    }

    /// Where this program is, whatever it was started as.
    static func executable() -> String {
      var path = [WCHAR](repeating: 0, count: 4096)
      let count = GetModuleFileNameW(nil, &path, DWORD(path.count))
      return String(decoding: path[0..<Int(count)], as: UTF16.self)
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
