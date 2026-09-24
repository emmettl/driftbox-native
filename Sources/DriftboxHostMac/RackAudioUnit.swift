#if canImport(AVFoundation)
  import DriftboxHost
  import AVFoundation
  import Synchronization

  /// The rack as an Audio Unit: a stereo instrument with no inputs, as the engine's is — what the
  /// app hosts in an `AVAudioEngine`, and what an AUv3 extension would wrap.
  ///
  /// It plays a `RackHost` it is given rather than one of its own, because the host is where the
  /// rack's owner keeps what it has loaded: patches, and audio decoded and breaks rendered at the
  /// host's rate. So the unit plays at that rate and no other, and says so to anyone who asks for
  /// a different one, rather than playing every sample at the wrong pitch.
  ///
  /// The render block captures a pointer to the host and nothing else. The host outlives render
  /// resources: `AVAudioEngine` deallocates every unit when it stops, which it does on its own
  /// whenever the output device changes, and the rack has to carry on from where it was.
  public final class RackAudioUnit: AUAudioUnit {
    public static let componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6472_636B,  // 'drck'
      componentManufacturer: 0x6472_6662,  // 'drfb'
      componentFlags: 0, componentFlagsMask: 0)

    /// What it plays. Setting it sets the output's rate to the host's.
    public var host: RackHost? {
      didSet {
        hostPointer.pointee = host
        if let host, host.sampleRate != outputBus.format.sampleRate,
          let format = AVAudioFormat(standardFormatWithSampleRate: host.sampleRate, channels: 2)
        {
          try? outputBus.setFormat(format)
        }
      }
    }

    /// The patch as a document, and its name, for a host saving the unit's state: kept by the
    /// rack's owner, who knows how a patch is written, as it changes.
    public let saved = Mutex<(document: String, name: String)?>(nil)
    /// A host restoring a state it saved: the document to open, and its name if it had one.
    /// Called on whatever thread the host restores from.
    public var restore: (@Sendable (_ document: String, _ name: String?) -> Void)?

    /// What the render block reads the host through, so that the block captures no object.
    private let hostPointer = UnsafeMutablePointer<RackHost?>.allocate(capacity: 1)
    private var outputBus: AUAudioUnitBus
    private var outputBuses: AUAudioUnitBusArray!

    static let patchKey = "patch"
    static let nameKey = "name"

    public override init(
      componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []
    ) throws {
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      outputBus = try AUAudioUnitBus(format: format)
      hostPointer.initialize(to: nil)
      try super.init(componentDescription: componentDescription, options: options)
      outputBuses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
      maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBuses }

    /// Stereo at the host's rate, or nothing.
    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
      guard format.channelCount == 2 else { return false }
      return host.map { $0.sampleRate == format.sampleRate } ?? true
    }

    public override func allocateRenderResources() throws {
      if let host, host.sampleRate != outputBus.format.sampleRate {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
      }
      try super.allocateRenderResources()
    }

    public override var fullState: [String: Any]? {
      get {
        var state = super.fullState ?? [:]
        if let saved = saved.withLock({ $0 }) {
          state[Self.patchKey] = saved.document
          state[Self.nameKey] = saved.name
        }
        return state
      }
      set {
        super.fullState = newValue
        if let document = newValue?[Self.patchKey] as? String {
          restore?(document, newValue?[Self.nameKey] as? String)
        }
      }
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
      // Captures the pointer and nothing else: the render block must not touch `self`.
      let hostPointer = hostPointer
      return { _, _, frameCount, _, outputData, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else {
          return kAudioUnitErr_InvalidParameter
        }
        let frames = Int(frameCount)
        let l = left.assumingMemoryBound(to: Float.self)
        let r = right.assumingMemoryBound(to: Float.self)
        guard let host = hostPointer.pointee else {
          l.update(repeating: 0, count: frames)
          r.update(repeating: 0, count: frames)
          return noErr
        }
        host.render(frames: frames, left: l, right: r)
        return noErr
      }
    }

    deinit {
      hostPointer.deinitialize(count: 1)
      hostPointer.deallocate()
    }
  }
#endif
