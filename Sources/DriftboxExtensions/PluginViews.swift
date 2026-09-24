#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxApp
  import SwiftUI

  /// The rack's face in another app's window: the Mac app's own rack window, on the rack the
  /// plug-in is playing — its patches, its fronts and back, its cables — or, until the app has
  /// readied the unit and there is a rack to show, word that one is coming.
  public struct RackPluginView: View {
    let plugin: RackPlugin

    public init(plugin: RackPlugin) { self.plugin = plugin }

    public var body: some View {
      if let face = plugin.face {
        // Played by the app it is in, not attached to a device here.
        RackWindow(rack: face) {}
      } else {
        Waiting(what: "rack")
      }
    }
  }

  /// The groovebox's face in another app's window: its editor, on the session the plug-in is
  /// playing, with the visuals behind it; or word that it is coming.
  public struct GrooveboxPluginView: View {
    let plugin: GrooveboxPlugin

    public init(plugin: GrooveboxPlugin) { self.plugin = plugin }

    public var body: some View {
      if let session = plugin.session, let stage = plugin.stage {
        GrooveboxPluginFace(player: session, stage: stage) { plugin.choose($0) }
      } else {
        Waiting(what: "groovebox")
      }
    }
  }

  /// Before the app has readied the unit, there is nothing to show but that.
  struct Waiting: View {
    let what: String

    var body: some View {
      Text("The \(what) appears once the app is ready to play it.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background(Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255))
    }
  }
#endif
