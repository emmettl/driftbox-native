#if canImport(AVFoundation)
  import DriftboxHost
  import AVFoundation
  import Synchronization

  /// One of Driftbox's instruments as an Audio Unit — the rack, the groovebox — stereo with no
  /// inputs, as an AUv3 extension carries it into other apps. What the two share is here; each is a
  /// subclass that says which it is and what it plays.
  ///
  /// It plays a `RenderSource` it is given rather than a host of its own, because the host is
  /// where the instrument's owner keeps what it has loaded: songs and patches, and audio decoded and
  /// breaks rendered at the host's rate. So the unit plays at that rate and no other, and says so to
  /// anyone who asks for a different one, rather than playing every sample at the wrong pitch —
  /// unless its owner makes the host at whatever rate it is asked for, which `prepare` is for.
  ///
  /// What an app loading it says reaches the owner off the render thread: the MIDI in its render
  /// events, through a ring; its tempo and whether its transport is moving, read as each block is
  /// rendered; and the preset it chose. The render block captures one pointer and nothing else.
  public class InstrumentAudioUnit: AUAudioUnit {
    /// What it plays. Setting it sets the output's rate to the source's.
    public var source: RenderSource? {
      didSet {
        shared.pointee.target = source.map {
          Shared.Target(context: $0.context, render: $0.render, locate: $0.locate)
        }
        // A new source has been put nowhere yet.
        shared.pointee.expectedBeat = .nan
        if let source, source.sampleRate != outputBus.format.sampleRate,
          let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 2)
        {
          try? outputBus.setFormat(format)
        }
      }
    }

    /// The key a saved state keeps the document under: what kind of document it is.
    class var documentKey: String { "document" }

    /// The document the instrument plays, and its name, for a host saving the unit's state: kept by
    /// the owner, who knows how one is written, as it changes.
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

    /// What the render block reads and writes, at an address that does not move: what it renders,
    /// the MIDI heard, and the app's tempo and transport as last read.
    struct Shared: ~Copyable {
      /// A source without its owner, which the render thread must not retain or release.
      struct Target {
        let context: UnsafeMutableRawPointer
        let render: RenderSource.Render
        let locate: RenderSource.Locate?
      }
      var target: Target?
      /// The rate the output runs at, which the app's beats are counted against.
      var sampleRate = 48000.0
      /// The render thread's own: the beat the app's transport should be on at the next block if
      /// it has neither jumped nor stopped, and whether it was moving, as of the last block.
      var expectedBeat = Double.nan
      var wasMoving = false
      /// Whether the render thread puts the instrument where the app's transport is, which it does
      /// once the app has said both where that is and whether it moves.
      let locates = Atomic<Bool>(false)
      /// Set by the owner when it has moved the instrument itself — a song remade at a new tempo,
      /// taken up at a step — so the next block puts it back where the app is.
      let again = Atomic<Bool>(false)

      /// Beats that far apart are the same place: the app's tempo changing inside a block moves it
      /// a little from where the last block's tempo said, and that is no jump.
      static let sameBeat = 0.02
      let midi = UnsafeMutablePointer<UInt32>.allocate(capacity: Shared.ring)
      let written = Atomic<Int>(0)
      let read = Atomic<Int>(0)
      let tempo = Atomic<UInt64>(0)
      /// -1 until the app says, then 0 or 1.
      let moving = Atomic<Int>(-1)
      var context: AUHostMusicalContextBlock?
      var transport: AUHostTransportStateBlock?
      /// Each parameter's value, by address: a float's bits, with `Shared.moved` set when the app
      /// moved it and the owner has not yet taken it. Written from the app's threads and the render
      /// thread both, read by the owner; the last value written is the one that counts.
      var parameters: UnsafeMutablePointer<Atomic<UInt64>>?
      var parameterCount = 0

      static let ring = 1024
      static let moved: UInt64 = 1 << 32

      /// The app moved parameter `address` to `value`: from its automation in the render events, or
      /// from its own controls through the tree. A value it already has is not a move — which is
      /// how the owner shows the app a value without hearing it back as one.
      func move(_ address: Int, to value: Float) {
        guard let parameters, address >= 0, address < parameterCount else { return }
        let bits = UInt64(value.bitPattern)
        if parameters[address].load(ordering: .relaxed) & 0xFFFF_FFFF == bits { return }
        parameters[address].store(bits | Shared.moved, ordering: .releasing)
      }

      func value(_ address: Int) -> Float {
        guard let parameters, address >= 0, address < parameterCount else { return 0 }
        return Float(bitPattern: UInt32(truncatingIfNeeded: parameters[address].load(ordering: .relaxed)))
      }
    }
    private let shared: UnsafeMutablePointer<Shared>
    private var outputBus: AUAudioUnitBus
    private var outputBuses: AUAudioUnitBusArray!

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

    /// Stereo at the source's rate, or nothing — unless the owner makes one at any rate.
    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
      guard format.channelCount == 2 else { return false }
      return prepare != nil || source.map { $0.sampleRate == format.sampleRate } ?? true
    }

    public override func allocateRenderResources() throws {
      prepare?(outputBus.format.sampleRate)
      if let source, source.sampleRate != outputBus.format.sampleRate {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
      }
      // The app's clock, as it gives it to the unit: read on the render thread, as it must be.
      shared.pointee.sampleRate = outputBus.format.sampleRate
      shared.pointee.expectedBeat = .nan
      shared.pointee.context = musicalContextBlock
      shared.pointee.transport = transportStateBlock
      try super.allocateRenderResources()
    }

    public override func deallocateRenderResources() {
      super.deallocateRenderResources()
      shared.pointee.context = nil
      shared.pointee.transport = nil
    }

    // MARK: - Parameters

    /// Give the app `count` parameters to automate, at addresses 0 up to it, under `groups`; each
    /// shown as `display` says. Once, as the unit is made, before the app asks what it has: an app
    /// keeps automation by address, so the parameters are the same whatever is loaded.
    public func publish(
      _ groups: [AUParameterGroup], count: Int, display: @escaping @Sendable (Int, Float) -> String
    ) {
      let slots = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: count)
      for address in 0..<count { (slots + address).initialize(to: Atomic(0)) }
      shared.pointee.parameters = slots
      shared.pointee.parameterCount = count
      let tree = AUParameterTree.createTree(withChildren: groups)
      Self.connect(tree, to: shared, display: display)
      parameterTree = tree
    }

    /// The tree's hooks, made here rather than in a method of the unit so they capture the pointer
    /// and nothing else, as the render block does: the app calls them on any thread it likes.
    private static func connect(
      _ tree: AUParameterTree, to shared: UnsafeMutablePointer<Shared>,
      display: @escaping @Sendable (Int, Float) -> String
    ) {
      let held = SharedPointer(shared)
      tree.implementorValueObserver = { parameter, value in
        held.pointer.pointee.move(Int(parameter.address), to: value)
      }
      tree.implementorValueProvider = { parameter in
        held.pointer.pointee.value(Int(parameter.address))
      }
      tree.implementorStringFromValueCallback = { parameter, value in
        display(Int(parameter.address), value?.pointee ?? parameter.value)
      }
    }

    /// What the app moved since last asked, by address, as their latest values. From one thread
    /// only, the owner's.
    public func movedParameters() -> [(address: Int, value: Float)] {
      guard let parameters = shared.pointee.parameters else { return [] }
      var moves: [(address: Int, value: Float)] = []
      for address in 0..<shared.pointee.parameterCount {
        var bits = parameters[address].load(ordering: .acquiring)
        while bits & Shared.moved != 0 {
          let (exchanged, now) = parameters[address].compareExchange(
            expected: bits, desired: bits & 0xFFFF_FFFF, ordering: .acquiringAndReleasing)
          if exchanged {
            moves.append((address, Float(bitPattern: UInt32(truncatingIfNeeded: bits))))
            break
          }
          bits = now
        }
      }
      return moves
    }

    /// Show the app what parameter `address` is at now, moved by the owner — a knob turned on the
    /// unit's face, a preset opened — so its controls follow and it can record the move; without
    /// hearing it back as the app's own.
    ///
    /// Never over a move of the app's not yet taken: the app moves its parameters on threads of its
    /// own while the owner shows it the song, and a move shown over would be lost. That move is the
    /// newer, and the owner takes it next time.
    public func show(_ value: Float, at address: Int) {
      guard let parameters = shared.pointee.parameters, address >= 0, address < shared.pointee.parameterCount
      else { return }
      let current = parameters[address].load(ordering: .acquiring)
      let bits = UInt64(value.bitPattern)
      guard current & Shared.moved == 0, current != bits,
        parameters[address].compareExchange(
          expected: current, desired: bits, ordering: .acquiringAndReleasing
        )
        .exchanged
      else { return }
      parameterTree?.parameter(withAddress: AUParameterAddress(address))?.setValue(value, originator: nil)
    }

    public override var fullState: [String: Any]? {
      get {
        var state = super.fullState ?? [:]
        if let saved = saved.withLock({ $0 }) {
          state[Self.documentKey] = saved.document
          state[Self.nameKey] = saved.name
        }
        return state
      }
      set {
        super.fullState = newValue
        if let document = newValue?[Self.documentKey] as? String {
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

    /// Whether the render thread puts the instrument where the app's transport is — starting,
    /// stopping and jumping with it — rather than the owner following its transport as changes.
    public var appLocates: Bool { shared.pointee.locates.load(ordering: .relaxed) }

    /// Put the instrument where the app's transport is again at the next block: for an owner that
    /// has moved it itself, as remaking a song at a new tempo does.
    public func locateAgain() { shared.pointee.again.store(true, ordering: .relaxed) }

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
          let type = current.pointee.head.eventType
          if type == .parameter || type == .parameterRamp {
            // Automation, sample by sample in the app, taken as it arrives: the song it moves is
            // remade as a whole, which a block at a time is already more often than it can be.
            let parameter = current.pointee.parameter
            shared.pointee.move(Int(parameter.parameterAddress), to: parameter.value)
          } else if type == .MIDI {
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
        var tempo = 0.0
        var beat = Double.nan
        if let context = shared.pointee.context {
          // Not a number until the app writes one: an app can say it answered and leave the beat
          // alone, and a beat of nought every block while moving would be a jump every block.
          var at = Double.nan
          if context(&tempo, nil, nil, &at, nil, nil) {
            if tempo > 0 { shared.pointee.tempo.store(tempo.bitPattern, ordering: .relaxed) }
            beat = at
          }
        }
        var moving: Bool?
        if let transport = shared.pointee.transport {
          var flags = AUHostTransportStateFlags()
          if transport(&flags, nil, nil, nil) {
            moving = flags.contains(.moving)
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
        guard let target = shared.pointee.target else {
          l.update(repeating: 0, count: frames)
          r.update(repeating: 0, count: frames)
          return noErr
        }
        // Where the app's transport is, when it has started or stopped or jumped since the last
        // block — a jump being a beat other than the one the last block's tempo led to, which is
        // the app's cycle going round, or its playhead moved — put the instrument there before
        // this block is rendered, so it starts on the block the app does.
        if let locate = target.locate, let moving, beat.isFinite {
          let expected = shared.pointee.expectedBeat
          let again =
            shared.pointee.again.load(ordering: .relaxed)
            && shared.pointee.again.exchange(false, ordering: .relaxed)
          if again || moving != shared.pointee.wasMoving || !expected.isFinite
            || abs(beat - expected) > Shared.sameBeat
          {
            locate(target.context, beat, moving)
            if !shared.pointee.locates.load(ordering: .relaxed) {
              shared.pointee.locates.store(true, ordering: .relaxed)
            }
          }
          shared.pointee.wasMoving = moving
          shared.pointee.expectedBeat =
            moving && tempo > 0 ? beat + Double(frames) * tempo / (60 * shared.pointee.sampleRate) : beat
        }
        target.render(target.context, frames, l, r)
        return noErr
      }
    }

    deinit {
      if let parameters = shared.pointee.parameters {
        parameters.deinitialize(count: shared.pointee.parameterCount)
        parameters.deallocate()
      }
      shared.pointee.midi.deallocate()
      shared.deinitialize(count: 1)
      shared.deallocate()
    }
  }

  /// The shared state's address, for the tree's hooks to carry across threads.
  private struct SharedPointer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<InstrumentAudioUnit.Shared>
    init(_ pointer: UnsafeMutablePointer<InstrumentAudioUnit.Shared>) { self.pointer = pointer }
  }
#endif
