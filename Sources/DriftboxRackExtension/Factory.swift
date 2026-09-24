#if canImport(AVFoundation) && canImport(CoreAudioKit)
  import AVFoundation
  import CoreAudioKit
  import DriftboxExtensions
  import DriftboxHostMac
  import SwiftUI

  /// What an app loading the extension asks for: the rack's Audio Unit, and its face in the app's
  /// window. One class is both, as an Audio Unit extension with a face has it, named in the
  /// extension's Info.plist by the Objective-C name it gives here, so that name does not move with
  /// the module's.
  @objc(DriftboxRackViewController)
  public final class RackViewController: AUViewController, AUAudioUnitFactory {
    /// The rack behind the unit, once the app has asked for one; the face is shown when both it and
    /// the view are there, in whichever order they come.
    private var plugin: RackPlugin?
    private var hosting: NSHostingView<AnyView>?

    public override func loadView() {
      let hosting = NSHostingView(rootView: content)
      view = hosting
      self.hosting = hosting
      preferredContentSize = NSSize(width: 900, height: 760)
    }

    private var content: AnyView {
      plugin.map { AnyView(RackPluginView(plugin: $0)) } ?? AnyView(Color.black)
    }

    /// On whatever thread the app asks from: the view's own is the main one, and the face reaches it
    /// there.
    nonisolated public func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit
    {
      let unit = try RackAudioUnit(componentDescription: description)
      RackPlugin.attach(to: unit)
      let plugin = RackPlugin.onMain { [held = Held(unit: unit)] in held.unit.owner as? RackPlugin }
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.plugin = plugin
          self.hosting?.rootView = self.content
        }
      }
      return unit
    }
  }
#endif
