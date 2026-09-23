import DriftboxDSP

// What a metered module shows, carried off the render thread.
//
// The reference's worklet asks each metered module for a reading every eight blocks and posts it,
// allocating as it goes. Here the render thread may not allocate, and a tuner's reading is an
// autocorrelation it should not spend time on either; nor may another thread read a processor
// that is being written. So each metered module has a mirror: a module of its own kind, with
// buffers of its own, into which the render thread copies what a reading is made from — a few
// numbers, forty-eight waveform points, a tuner's history — and nothing else. A reading is then
// taken from the mirror, by the module's own code, on whichever thread wants it.
//
// A looper's mirror is the exception. Its reading samples forty-eight points from up to thirty
// seconds of loop, and copying the loop to sample it would be absurd, so the points are sampled
// into the mirror instead.

/// A metered module's copy.
public enum MeterMirror {
  case vu(VUMeter)
  case tuner(Tuner)
  case looper(LooperShot)

  /// A mirror for `processor`, or nil for one that shows nothing.
  static func make(for processor: RackProcessor, sampleRate: Double) -> MeterMirror? {
    switch processor {
    case .control(.meter): .vu(VUMeter(sampleRate: sampleRate))
    case .control(.tuner): .tuner(Tuner(sampleRate: sampleRate))
    case .space(.looper): .looper(LooperShot(sampleRate: sampleRate))
    default: nil
    }
  }

  /// Forty-eight waveform points and a tuner's 2048 samples of history: `VUMeter.points`,
  /// `Tuner.points` and `Tuner.historyLength`, written out because another file's static is a call
  /// the render path cannot see into. `RackHostTests` holds them to each other.
  static let points = 48
  static let history = 2048

  /// Copy what a reading is made from out of `processor`.
  @_noAllocation
  mutating func take(from processor: RackProcessor) {
    switch (self, processor) {
    case (.vu(var mirror), .control(.meter(let source))):
      mirror.envelope = source.envelope
      mirror.blockSquares = source.blockSquares
      mirror.blockFrames = source.blockFrames
      mirror.peak = source.peak
      for point in 0..<48 { mirror.waveform[point] = source.waveform[point] }
      self = .vu(mirror)
    case (.tuner(var mirror), .control(.tuner(let source))):
      mirror.write = source.write
      mirror.filled = source.filled
      mirror.blockSquares = source.blockSquares
      mirror.blockFrames = source.blockFrames
      mirror.peak = source.peak
      for index in 0..<2048 { mirror.history[index] = source.history[index] }
      for point in 0..<48 { mirror.waveform[point] = source.waveform[point] }
      self = .tuner(mirror)
    case (.looper(var mirror), .space(.looper(let source))):
      mirror.take(from: source)
      self = .looper(mirror)
    default:
      break
    }
  }

  /// The reading, as the module itself would give it.
  public func reading() -> MeterReading {
    switch self {
    case .vu(let mirror): mirror.meter()
    case .tuner(let mirror): mirror.meter()
    case .looper(let mirror): mirror.meter()
    }
  }

  func release() {
    switch self {
    case .vu(let mirror): mirror.waveform.deallocate()
    case .tuner(let mirror): mirror.release()
    case .looper(let mirror): mirror.waveform.deallocate()
    }
  }
}

/// What a looper's reading is made from: its level, its peak, where it is in how long a loop,
/// and forty-eight points sampled from the loop as `Looper.meter` samples them.
public struct LooperShot {
  let sampleRate: Double
  var meanSquare = 0.0
  var peak = 0.0
  var position = 0
  var length = 0
  let waveform: UnsafeMutablePointer<Float>

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    waveform = .allocate(capacity: 48)
    waveform.initialize(repeating: 0, count: 48)
  }

  @_noAllocation
  mutating func take(from source: Looper) {
    meanSquare = source.meanSquare
    peak = source.peak
    position = source.position
    length = source.length
    for point in 0..<48 {
      guard length > 0 else {
        waveform[point] = 0
        continue
      }
      let index = min(length - 1, Int(jsFloor(Double(point * length) / 48)))
      var sample = (Double(source.left[index]) + Double(source.right[index])) * 0.5
      if sample < -1 { sample = -1 } else if sample > 1 { sample = 1 }
      waveform[point] = Float(sample)
    }
  }

  func meter() -> MeterReading {
    let level = meanSquare.squareRoot()
    return MeterReading(
      level: level, peak: peak, envelope: level,
      waveform: Array(UnsafeBufferPointer(start: waveform, count: 48)),
      loopPosition: length > 0 ? Double(position) / Double(length) : 0,
      loopSeconds: Double(length) / sampleRate)
  }
}
