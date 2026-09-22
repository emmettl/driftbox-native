#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import SwiftUI

  @main
  struct DriftboxApp: App {
    @State private var player = Player()

    init() {
      // A bare executable, not a bundle: without this there is no window and no menu.
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
      WindowGroup("Driftbox") {
        ContentView(player: player)
          .frame(minWidth: 1100, idealWidth: 1100, minHeight: 720, idealHeight: 720)
      }
      // The window is the user's size, not whatever a long chain or a wide grid would like.
      .windowResizability(.contentMinSize)
    }
  }
#else
  @main
  struct DriftboxApp {
    static func main() { print("Driftbox needs SwiftUI") }
  }
#endif
