#if canImport(AVFoundation)
  import DriftboxHost
  import AVFoundation
  import Synchronization

  /// The rack as an Audio Unit: a stereo instrument with no inputs, as the engine's is — what an
  /// app hosts in an `AVAudioEngine`, and what the AUv3 extension carries into other apps.
  ///
  /// It plays a `RackHost` it is given rather than one of its own, because the host is where the
  /// rack's owner keeps what it has loaded: patches, and audio decoded and breaks rendered at the
  /// host's rate. So the unit plays at that rate and no other, and says so to anyone who asks for
  /// a different one, rather than playing every sample at the wrong pitch — unless its owner makes
  /// the host at whatever rate it is asked for, which `prepare` is for.
  ///
  /// What an app loading it says reaches the owner off the render thread: the MIDI in its render
  /// events, through a ring; its tempo and whether its transport is moving, read as each block is
  /// rendered; and the preset it chose. The render block captures one pointer and nothing else.
  public final class RackAudioUnit: AUAudioUnit {
    public static let componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6472_636B,  // 'drck'
      componentManufacturer: 0x4472_6662,  // 'Drfb': an OSType of all lower case is Apple's
      componentFlags: 0, componentFlagsMask: 0)

    /// What it plays. Setting it sets the output's rate to the host's.
    public var host: RackHost? {
      didSet {
        shared.pointee.host = host
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
    /// Called with the rate the output will run at as render resources are allocated, on whatever
    /// thread the app allocates them from: for an owner that makes its host at the rate it is asked
    /// for, before the unit checks the two agree.
    public var prepare: ((Double) -> Void)?
    /// Whatever keeps the unit's owner alive for as long as the unit is.
    public var owner: AnyObject?

    /// The presets an app can choose from, by name, and what to do when it chooses one.
    public var presetNames: [String] = []
    public var choosePreset: ((Int) -> Void)?
    private var chosen: AUAudioUnitPreset?

    /// What the render block reads and writes, at an address that does not move: the host, the
    /// MIDI heard, and the app's tempo and transport as last read.
    struct Shared: ~Copyable {
      var host: RackHost?
      let midi = UnsafeMutablePointer<UInt32>.allocate(capacity: Shared.ring)
      let written = Atomic<Int>(0)
      let read = Atomic<Int>(0)
      let tempo = Atomic<UInt64>(0)
      /// -1 until the app says, then 0 or 1.
      let moving = Atomic<Int>(-1)
      var context: AUHostMusicalContextBlock?
      var transport: AUHostTransportStateBlock?

      static let ring = 1024
    }
    private let shared: UnsafeMutablePointer<Shared>
    private var outputBus: AUAudioUnitBus
    private var outputBuses: AUAudioUnitBusArray!

    static let patchKey = "patch"
    static let nameKey = "name"

    public override init(
      componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []
    ) throws {
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      outputBus = try AUAudioUnitBus(format: format)
      shared = .allocate(capacity: 1)
      shared.initialize(to: Shared())
      try super.init(componentDescription: componentDescription, options: options)
      outputBuses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
      maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBuses }

    /// Stereo at the host's rate, or nothing — unless the owner makes one at any rate.
    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
      guard format.channelCount == 2 else { return false }
      return prepare != nil || host.map { $0.sampleRate == format.sampleRate } ?? true
    }

    public override func allocateRenderResources() throws {
      prepare?(outputBus.format.sampleRate)
      if let host, host.sampleRate != outputBus.format.sampleRate {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
      }
      // The app's clock, as it gives it to the unit: read on the render thread, as it must be.
      shared.pointee.context = musicalContextBlock
      shared.pointee.transport = transportStateBlock
      try super.allocateRenderResources()
    }

    public override func deallocateRenderResources() {
      super.deallocateRenderResources()
      shared.pointee.context = nil
      shared.pointee.transport = nil
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

    // MARK: - Presets

    public override var factoryPresets: [AUAudioUnitPreset]? {
      presetNames.enumerated().map { number, name in
        let preset = AUAudioUnitPreset()
        preset.number = number
        preset.name = name
        return preset
      }
    }

    public override var currentPreset: AUAudioUnitPreset? {
      get { chosen }
      set {
        chosen = newValue
        if let number = newValue?.number, number >= 0, number < presetNames.count { choosePreset?(number) }
      }
    }

    // MARK: - What the app says, for the owner

    /// The next MIDI message the app sent, as its bytes; nil when there is none waiting. From one
    /// thread only, the owner's.
    public func nextMIDI() -> [UInt8]? {
      let read = shared.pointee.read.load(ordering: .relaxed)
      guard read < shared.pointee.written.load(ordering: .acquiring) else { return nil }
      let word = shared.pointee.midi[read % Shared.ring]
      shared.pointee.read.store(read + 1, ordering: .releasing)
      let count = Int(word >> 24)
      let bytes = [
        UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8),
        UInt8(truncatingIfNeeded: word),
      ]
      return Array(bytes.prefix(count))
    }

    /// The app's tempo, as of the last block rendered; nil before it has said.
    public var appTempo: Double? {
      let bits = shared.pointee.tempo.load(ordering: .relaxed)
      return bits == 0 ? nil : Double(bitPattern: bits)
    }

    /// Whether the app's transport is moving, as of the last block; nil before it has said.
    public var appPlaying: Bool? {
      switch shared.pointee.moving.load(ordering: .relaxed) {
      case 0: false
      case 1: true
      default: nil
      }
    }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
      // Captures the pointer and nothing else: the render block must not touch `self`.
      let shared = shared
      return { _, _, frameCount, _, outputData, events, _ in
        // MIDI into the ring, for the owner; a full ring drops the newest, as the command rings do.
        var event = events
        while let current = event {
          if current.pointee.head.eventType == .MIDI {
            let midi = current.pointee.MIDI
            let written = shared.pointee.written.load(ordering: .relaxed)
            if written - shared.pointee.read.load(ordering: .acquiring) < Shared.ring {
              shared.pointee.midi[written % Shared.ring] =
                UInt32(min(3, midi.length)) << 24 | UInt32(midi.data.0) << 16 | UInt32(midi.data.1) << 8
                | UInt32(midi.data.2)
              shared.pointee.written.store(written + 1, ordering: .releasing)
            }
          }
          event = UnsafePointer(current.pointee.head.next)
        }
        // The app's tempo and transport, when it gives them.
        if let context = shared.pointee.context {
          var tempo = 0.0
          if context(&tempo, nil, nil, nil, nil, nil), tempo > 0 {
            shared.pointee.tempo.store(tempo.bitPattern, ordering: .relaxed)
          }
        }
        if let transport = shared.pointee.transport {
          var flags = AUHostTransportStateFlags()
          if transport(&flags, nil, nil, nil) {
            shared.pointee.moving.store(flags.contains(.moving) ? 1 : 0, ordering: .relaxed)
          }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else {
          return kAudioUnitErr_InvalidParameter
        }
        let frames = Int(frameCount)
        let l = left.assumingMemoryBound(to: Float.self)
        let r = right.assumingMemoryBound(to: Float.self)
        guard let host = shared.pointee.host else {
          l.update(repeating: 0, count: frames)
          r.update(repeating: 0, count: frames)
          return noErr
        }
        host.render(frames: frames, left: l, right: r)
        return noErr
      }
    }

    deinit {
      shared.pointee.midi.deallocate()
      shared.deinitialize(count: 1)
      shared.deallocate()
    }
  }
#endif
