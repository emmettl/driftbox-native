#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxEngine
  import DriftboxSeq

  /// The engine as an Audio Unit: a stereo instrument with no inputs, which is what a player
  /// hosts in an `AVAudioEngine` and what an AUv3 extension wraps.
  ///
  /// The render block captures a pointer to the host and nothing else — no closure state that
  /// the audio thread would retain or release.
  public final class DriftboxAudioUnit: AUAudioUnit {
    public static let componentDescription = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6472_6674,  // 'drft'
      componentManufacturer: 0x6472_6662,  // 'drfb'
      componentFlags: 0, componentFlagsMask: 0)

    /// The engine host, made when render resources are allocated for a known sample rate.
    public private(set) var host: EngineHost? {
      didSet { hostPointer.pointee = host }
    }
    /// What the render block reads the host through, so that the block captures no object.
    private let hostPointer = UnsafeMutablePointer<EngineHost?>.allocate(capacity: 1)
    private var outputBus: AUAudioUnitBus
    private var outputBuses: AUAudioUnitBusArray!
    /// A few things asked for before the host exists: a song, a play. Sent on once it does.
    private var pendingSong: Song?
    private var pendingCommands: [Command] = []

    public override init(
      componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []
    )
      throws
    {
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      outputBus = try AUAudioUnitBus(format: format)
      hostPointer.initialize(to: nil)
      try super.init(componentDescription: componentDescription, options: options)
      outputBuses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
      maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { outputBuses }

    public override func allocateRenderResources() throws {
      try super.allocateRenderResources()
      let host = EngineHost(sampleRate: outputBus.format.sampleRate)
      self.host = host
      if let song = pendingSong { host.load(song) }
      for command in pendingCommands { host.send(command) }
      pendingSong = nil
      pendingCommands = []
    }

    public override func deallocateRenderResources() {
      host = nil
      super.deallocateRenderResources()
    }

    public func load(_ song: Song) {
      if let host { host.load(song) } else { pendingSong = song }
    }

    public func send(_ command: Command) {
      if let host { host.send(command) } else { pendingCommands.append(command) }
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
          for index in 0..<frames {
            l[index] = 0
            r[index] = 0
          }
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
