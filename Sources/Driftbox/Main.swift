#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxApp
  import DriftboxSession
  import SwiftUI

  @main
  struct Driftbox: App {
    @State private var studio: Studio
    @State private var stage: Stage
    private var player: Session { studio.session }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
      // A bare executable, not a bundle: without this there is no window and no menu.
      NSApplication.shared.setActivationPolicy(.regular)
      // A bundle's icon comes from its Info.plist; a bare executable, run with `swift run`, would
      // otherwise sit in the Dock as a blank one.
      if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil, let icon = AppIcon.image {
        NSApplication.shared.applicationIconImage = icon
      }
      NSApplication.shared.activate(ignoringOtherApps: true)
      let studio = Studio()
      _studio = State(initialValue: studio)
      _stage = State(initialValue: Stage(player: studio.session))
    }

    var body: some Scene {
      WindowGroup("Driftbox") {
        ContentView(player: player, stage: stage)
          .frame(minWidth: 1100, idealWidth: 1100, minHeight: 720, idealHeight: 720)
          // The delegate hears about files before there is a window to open them into, so it is
          // given somewhere to put them the moment there is one. The visuals window comes back
          // with the main one, if it was open when the app last quit.
          .onAppear {
            if !delegate.attach(SongFiles(player: player)) { player.restore() }
            stage.restore()
          }
      }
      // The window is the user's size, not whatever a long chain or a wide grid would like.
      .windowResizability(.contentMinSize)
      // One song, one window, so a file arriving from the Finder is opened into the window that
      // is already here. Left to itself the group answers an open by making a second window, and
      // two windows on one player are two views of the same song pretending to be documents.
      .handlesExternalEvents(matching: [])
      .commands { AppMenus(player: player, files: SongFiles(player: player), stage: stage) }

      // The rack is an instrument beside the groovebox, in a window of its own, playing through
      // the same device.
      Window("Rack", id: "rack") {
        RackWindow(rack: studio.rack) { studio.openRack() }
      }
      .defaultSize(width: 900, height: 860)

      // The guide, beside what it describes rather than over it.
      Window("Groovebox Guide", id: "help") {
        HelpWindow(.groovebox)
      }
      .defaultSize(width: 760, height: 640)

      Window("Rack Guide", id: "rack-help") {
        HelpWindow(.rack)
      }
      .defaultSize(width: 760, height: 640)

      Settings {
        SettingsView(player: player)
      }
    }
  }
#else
  @main
  struct Driftbox {
    static func main() { print("Driftbox needs SwiftUI") }
  }
#endif
