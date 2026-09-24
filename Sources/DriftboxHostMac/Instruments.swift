#if canImport(AVFoundation)
  import DriftboxHost
  import AVFoundation

  /// The rack as an Audio Unit: what the AUv3 extension carries into other apps, playing the
  /// `RackHost` its owner gives it. Its state keeps the patch.
  public final class RackAudioUnit: InstrumentAudioUnit {
    public static let componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6472_636B,  // 'drck'
      componentManufacturer: 0x4472_6662,  // 'Drfb': an OSType of all lower case is Apple's
      componentFlags: 0, componentFlagsMask: 0)

    /// What it plays; its output runs at the host's rate.
    public var host: RackHost? {
      didSet { source = host?.renderSource }
    }

    override class var documentKey: String { "patch" }
  }

  /// The groovebox as an Audio Unit: what the AUv3 extension carries into other apps, playing the
  /// `EngineHost` its owner gives it. Its state keeps the song.
  ///
  /// Not `DriftboxAudioUnit`, which makes an engine of its own for whatever loads it in-process —
  /// `driftbox-play` — and is given songs and commands: this one's owner has the engine, in a
  /// session, and the unit only plays it and carries in what the app says.
  public final class GrooveboxAudioUnit: InstrumentAudioUnit {
    public static let componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6472_6762,  // 'drgb'
      componentManufacturer: 0x4472_6662,  // 'Drfb'
      componentFlags: 0, componentFlagsMask: 0)

    /// What it plays; its output runs at the host's rate.
    public var host: EngineHost? {
      didSet { source = host?.renderSource }
    }

    override class var documentKey: String { "song" }
  }
#endif
