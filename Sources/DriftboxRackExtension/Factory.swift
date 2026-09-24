#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxExtensions
  import DriftboxHostMac

  /// What an app loading the extension asks for the rack's Audio Unit: the class the extension's
  /// Info.plist names, by the Objective-C name it gives here, so that name does not move with the
  /// module's.
  @objc(DriftboxRackFactory)
  public final class RackFactory: NSObject, AUAudioUnitFactory {
    public func beginRequest(with context: NSExtensionContext) {}

    public func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit {
      let unit = try RackAudioUnit(componentDescription: description)
      RackPlugin.attach(to: unit)
      return unit
    }
  }
#endif
