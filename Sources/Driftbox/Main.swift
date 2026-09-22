#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxApp
  import SwiftUI

  @main
  struct Driftbox: App {
    @State private var player = Player()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
      // A bare executable, not a bundle: without this there is no window and no menu.
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
      WindowGroup("Driftbox") {
        ContentView(player: player)
          .frame(minWidth: 1100, idealWidth: 1100, minHeight: 720, idealHeight: 720)
          // The delegate hears about files before there is a window to open them into, so it is
          // given somewhere to put them the moment there is one.
          .onAppear { delegate.attach(SongFiles(player: player)) }
      }
      // The window is the user's size, not whatever a long chain or a wide grid would like.
      .windowResizability(.contentMinSize)
      // One song, one window, so a file arriving from the Finder is opened into the window that
      // is already here. Left to itself the group answers an open by making a second window, and
      // two windows on one player are two views of the same song pretending to be documents.
      .handlesExternalEvents(matching: [])
      .commands { AppMenus(player: player, files: SongFiles(player: player)) }

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
