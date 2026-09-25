#if canImport(AVFoundation) && canImport(CoreAudioKit)
  import AVFoundation
  import CoreAudioKit
  import DriftboxExtensions
  import DriftboxHostMac
  import SwiftUI

  /// What an app loading the extension asks for: one of Driftbox's instruments as an Audio Unit —
  /// the rack or the groovebox, by the subtype it asks for — and its face in the app's window. One
  /// class is both, as an Audio Unit extension with a face has it, named in the extension's
  /// Info.plist by the Objective-C name it gives here, so that name does not move with the module's.
  /// Each unit an app makes has a controller of its own.
  @objc(DriftboxAudioUnitViewController)
  public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    /// The face of the unit made, once the app has asked for one; shown when both it and the view
    /// are there, in whichever order they come.
    private var face: AnyView?
    private var hosting: NSHostingView<AnyView>?

    public override func loadView() {
      let hosting = NSHostingView(rootView: content)
      view = hosting
      self.hosting = hosting
      preferredContentSize = size
    }

    private var content: AnyView { face ?? AnyView(Color.black) }
    /// What the face asks the app's window for: the rack's is taller than it is wide, and the
    /// groovebox's editor wider, with the inspector beside the grid.
    private var size = NSSize(width: 900, height: 760)

    /// On whatever thread the app asks from: the view's own is the main one, and the face reaches it
    /// there.
    nonisolated public func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit
    {
      let unit: InstrumentAudioUnit
      let face: @MainActor @Sendable () -> AnyView?
      let size: NSSize
      if description.componentSubType == GrooveboxAudioUnit.componentDescription.componentSubType {
        let groovebox = try GrooveboxAudioUnit(componentDescription: description)
        GrooveboxPlugin.attach(to: groovebox)
        let held = Held(unit: groovebox)
        face = { (held.unit.owner as? GrooveboxPlugin).map { AnyView(GrooveboxPluginView(plugin: $0)) } }
        size = NSSize(width: 1120, height: 800)
        unit = groovebox
      } else {
        let rack = try RackAudioUnit(componentDescription: description)
        RackPlugin.attach(to: rack)
        let held = Held(unit: rack)
        face = { (held.unit.owner as? RackPlugin).map { AnyView(RackPluginView(plugin: $0)) } }
        size = NSSize(width: 900, height: 760)
        unit = rack
      }
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.face = face()
          self.size = size
          self.hosting?.rootView = self.content
          if self.isViewLoaded { self.preferredContentSize = size }
        }
      }
      return unit
    }
  }
#endif
