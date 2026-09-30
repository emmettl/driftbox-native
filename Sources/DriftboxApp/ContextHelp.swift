#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxHelp
  import SwiftUI

  @MainActor
  enum MacHelp {
    static var isAvailable: Bool {
      Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String == HelpBook.identifier
        && Bundle.main.url(forResource: "Driftbox", withExtension: "help") != nil
    }

    static func open(_ anchor: String = "index") {
      NSHelpManager.shared.openHelpAnchor(anchor, inBook: HelpBook.identifier)
    }
  }

  /// A native help button. Bare SwiftPM executables and AU hosts do not contain the app's Help
  /// Book, so they show the same topic in a guide sheet instead of opening an unresolved anchor.
  struct ContextHelp: View {
    let destination: HelpBook.Destination
    let label: String
    @State private var showsGuide = false

    var body: some View {
      HelpLink {
        if MacHelp.isAvailable { MacHelp.open(destination.rawValue) } else { showsGuide = true }
      }
      .help(label)
      .accessibilityLabel(label)
      .sheet(isPresented: $showsGuide) {
        HelpWindow(
          guide: destination.isRack ? RackHelp.guide(for: .mac) : GrooveboxHelp.guide(for: .mac),
          topic: destination.topic
        )
        .frame(minWidth: 660, minHeight: 520)
        .toolbar {
          Button("Done") { showsGuide = false }.keyboardShortcut(.cancelAction)
        }
      }
    }
  }
#endif
