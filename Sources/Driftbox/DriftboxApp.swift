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
          .frame(minWidth: 900, minHeight: 560)
      }
    }
  }
#else
  @main
  struct DriftboxApp {
    static func main() { print("Driftbox needs SwiftUI") }
  }
#endif
