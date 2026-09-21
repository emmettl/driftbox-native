import DriftboxDSP

/// One source of a hit, as plain bytes: everything `RenderedSource` works out when a hit is built,
/// worked out ahead of time, with nothing behind it that needs counting or freeing.
public struct FixedSource {
  enum Kind: UInt8 {
    case oscillator, noise
  }

  var kind = Kind.oscillator
  var shape = WaveTable.Shape.sine
  /// Which of the pool's noise buffers this reads.
  var noiseBuffer = 0
  var gain = FixedTimeline(defaultValue: 0)
  var frequency = FixedTimeline(defaultValue: 0)
  var hasFilter = false
  var filterResponse = Biquad.Response.lowpass
  var filterFrequency = FixedTimeline(defaultValue: 0)
  var filterSwept = false
  var filterQ = 1.0
  var start = 0.0
  var stop = 0.0
  /// Where in its buffer a noise source starts reading, and how far it moves per frame.
  var position = 0.0
  var increment = 0.0
}

/// A hit, ready to play: a `VoiceSpec` and the moment it was struck, turned into plain bytes on a
/// thread that is allowed to allocate, so that the render thread — which is not — has only to
/// copy it. Small enough to pass through a ring.
public struct FixedVoiceSpec {
  /// A computed constant rather than a stored one: a stored global is initialised on first use,
  /// behind a lock, which is not something the render thread may wait on.
  public static var maximumSources: Int { 8 }

  var sourceCount = 0
  // Eight sources inline; see `FixedTimeline` for why not a generic fixed array.
  var s0 = FixedSource(), s1 = FixedSource(), s2 = FixedSource(), s3 = FixedSource()
  var s4 = FixedSource(), s5 = FixedSource(), s6 = FixedSource(), s7 = FixedSource()

  var gain = 0.0
  /// Which of the pool's drive curves, or -1 for a voice with no drive.
  var driveCurve = -1
  var hasFilter = false
  var filterResponse = Biquad.Response.lowpass
  var filterFrequency = FixedTimeline(defaultValue: 0)
  var filterSwept = false
  var filterQ = 1.0
  var panLeft = 1.0
  var panRight = 1.0
  var trim = FixedTimeline(defaultValue: 1)

  /// When the hit was struck, the first frame it is rendered on, and the first it is not.
  public var time = 0.0
  public var firstFrame = 0
  public var endFrame = 0
  /// When its sources stop: a voice still sounding at a later hit in its choke group is cut off.
  var endsAt = 0.0
  /// 0 for none. Voices with the same group cut each other off.
  public var chokeGroup: UInt8 = 0
  public var sendDelay: Float = 0
  public var sendReverb: Float = 0

  /// The same hit `frames` frames later. A song is prepared once against its own clock, from
  /// zero; every pass through it is placed on the engine's clock with this.
  @_noAllocation
  public mutating func shift(byFrames frames: Int, sampleRate: Double) {
    let seconds = Double(frames) / sampleRate
    time += seconds
    firstFrame += frames
    endFrame += frames
    endsAt += seconds
    filterFrequency.shift(by: seconds)
    trim.shift(by: seconds)
    for index in 0..<sourceCount {
      var source = source(index)
      source.start += seconds
      source.stop += seconds
      source.gain.shift(by: seconds)
      source.frequency.shift(by: seconds)
      source.filterFrequency.shift(by: seconds)
      setSource(source, at: index)
    }
  }

  @_noAllocation
  func source(_ index: Int) -> FixedSource {
    switch index {
    case 0: s0
    case 1: s1
    case 2: s2
    case 3: s3
    case 4: s4
    case 5: s5
    case 6: s6
    default: s7
    }
  }

  @_noAllocation
  mutating func setSource(_ source: FixedSource, at index: Int) {
    switch index {
    case 0: s0 = source
    case 1: s1 = source
    case 2: s2 = source
    case 3: s3 = source
    case 4: s4 = source
    case 5: s5 = source
    case 6: s6 = source
    default: s7 = source
    }
  }
}
