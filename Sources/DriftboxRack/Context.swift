// What a module sees besides its jacks and knobs, once per block. The reference hands these to
// `process` as trailing arguments that most modules ignore; here they travel together, so adding
// one never changes every module's signature again.

/// One slot of a module's bulk data — a sample, a pattern — as the graph holds it. `revision`
/// changes whenever the data does, which is how a module notices: the reference compares the
/// array's identity, and a pointer alone could be reused.
public struct DataBuffer {
  public var samples: UnsafePointer<Float>?
  public var count: Int
  public var revision: Int

  @_noAllocation
  public init(samples: UnsafePointer<Float>?, count: Int, revision: Int) {
    self.samples = samples
    self.count = count
    self.revision = revision
  }
}

/// A module's data slots, in the order its def names them.
public struct DataSlots {
  let base: UnsafeMutablePointer<DataBuffer>?
  public let count: Int

  @_noAllocation
  public subscript(index: Int) -> DataBuffer {
    guard let base, index >= 0, index < count else { return DataBuffer(samples: nil, count: 0, revision: 0) }
    return base[index]
  }
}

/// Audio from outside the rack: the host's buses, each a channel or two.
public struct HostInputs {
  let base: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
  public let buses: Int
  public let channels: Int

  /// `buses` buses of `channels` channels, bus-major.
  @_noAllocation
  public init(base: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?, buses: Int, channels: Int) {
    self.base = base
    self.buses = buses
    self.channels = channels
  }

  public static var none: HostInputs {
    @_noAllocation get { HostInputs(base: nil, buses: 0, channels: 0) }
  }

  /// Bus `bus`, channel `channel`, or nil when the host gave none.
  @_noAllocation
  public func buffer(bus: Int, channel: Int) -> UnsafeMutablePointer<Float>? {
    guard let base, bus >= 0, bus < buses, channel >= 0, channel < channels else { return nil }
    return base[bus * channels + channel]
  }
}

/// For a module that runs once but wants every voice separately — an arpeggiator reading the
/// notes held — each inlet's voices, as well as their sum on the ordinary inlet.
public struct VoiceInlets {
  let base: UnsafeMutablePointer<Slots>?
  public let count: Int

  @_noAllocation
  public subscript(inlet: Int) -> Slots? {
    guard let base, inlet >= 0, inlet < count else { return nil }
    return base[inlet]
  }
}

/// Whether a jack has a cable in it, which is not the same as whether it carries anything.
public struct Flags {
  let base: UnsafeMutablePointer<Bool>?
  public let count: Int

  @_noAllocation
  public subscript(index: Int) -> Bool {
    guard let base, index >= 0, index < count else { return false }
    return base[index]
  }
}

/// Which voice of how many this instance is, and scratch every voice of one module shares.
public struct VoiceInfo {
  public var voice: Int
  /// The voice of the stream it came from, when an expander made lanes out of it.
  public var sourceVoice: Int
  public var lane: Int
  public var lanes: Int
  public var voices: Int
  /// Doubles shared by every voice of the module, as many as its def asks for.
  public var shared: UnsafeMutablePointer<Double>?
  public var sharedCount: Int

  public static var single: VoiceInfo {
    VoiceInfo(voice: 0, sourceVoice: 0, lane: 0, lanes: 1, voices: 1, shared: nil, sharedCount: 0)
  }
}

public struct ProcessContext {
  public var frames: Int
  public var transport: Transport
  public var data: DataSlots
  public var host: HostInputs
  public var voiceInlets: VoiceInlets?
  public var inletConnected: Flags
  public var outletConnected: Flags
  public var voice: VoiceInfo

  @_noAllocation
  init(
    frames: Int, transport: Transport, data: DataSlots, host: HostInputs, voiceInlets: VoiceInlets?,
    inletConnected: Flags, outletConnected: Flags, voice: VoiceInfo
  ) {
    self.frames = frames
    self.transport = transport
    self.data = data
    self.host = host
    self.voiceInlets = voiceInlets
    self.inletConnected = inletConnected
    self.outletConnected = outletConnected
    self.voice = voice
  }
}

/// What a module shows its faceplate: a level, a peak, a waveform — for the meters and the
/// tuner, and a looper's position.
public struct MeterReading: Sendable {
  public var level: Double
  public var peak: Double
  public var envelope: Double
  public var waveform: [Float]
  public var frequency: Double?
  public var clarity: Double?
  public var loopPosition: Double?
  public var loopSeconds: Double?
  /// The notes an instrument has sounding, lowest first.
  public var notes: [Int]?

  public init(
    level: Double, peak: Double, envelope: Double, waveform: [Float], frequency: Double? = nil,
    clarity: Double? = nil, loopPosition: Double? = nil, loopSeconds: Double? = nil, notes: [Int]? = nil
  ) {
    self.level = level
    self.peak = peak
    self.envelope = envelope
    self.waveform = waveform
    self.frequency = frequency
    self.clarity = clarity
    self.loopPosition = loopPosition
    self.loopSeconds = loopSeconds
    self.notes = notes
  }
}
