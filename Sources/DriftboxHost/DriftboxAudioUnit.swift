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
    /// The last song it was given, so a host made again at a new sample rate can be given it too.
    private var loaded: Song?
    /// Commands asked for before there is a host at all. Sent on once there is.
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
      let rate = outputBus.format.sampleRate
      if let kept = host, kept.sampleRate == rate {
        // The same engine, carrying on from where it stopped.
      } else {
        let fresh = EngineHost(sampleRate: rate)
        if let loaded {
          fresh.load(loaded)
          // A new rate — an audio unit's host is free to change it between a stop and a start —
          // keeps the place in the song, which is a time and not a count of frames.
          if let kept = host {
            let frame = kept.songFrame.load(ordering: .relaxed)
            if frame > 0 { fresh.send(.seek(songFrame: Int(Double(frame) / kept.sampleRate * rate))) }
            if kept.playing.load(ordering: .relaxed) { fresh.send(.play) }
          }
        }
        host = fresh
      }
      for command in pendingCommands { host?.send(command) }
      pendingCommands = []
    }

    /// The host is kept. `AVAudioEngine` deallocates every unit when it stops — which it does on
    /// its own whenever the output device changes, a pair of headphones plugged in or an
    /// interface unplugged — and a host thrown away here came back from the next start with no
    /// song in it and the interface none the wiser: the music simply stopped. Nothing renders
    /// while deallocated, so keeping it costs nothing.
    public override func deallocateRenderResources() {
      super.deallocateRenderResources()
    }

    public func load(_ song: Song) {
      loaded = song
      host?.load(song)
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
