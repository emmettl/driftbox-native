/// A delay line read at a moving, fractional distance: the Web Audio `DelayNode`.
///
/// Owns raw storage and is not copyable, so that `process` can be allocation-free.
public struct DelayLine: ~Copyable {
  let buffer: UnsafeMutablePointer<Float>
  let length: Int
  let sampleRate: Double
  var writeIndex = 0

  /// A delay inside a feedback loop cannot be shorter than one render quantum in the browser,
  /// whatever it is asked for, because the loop is computed a quantum at a time.
  public static let minimumFramesInALoop = 128.0

  public init(maximumSeconds: Double, sampleRate: Double) {
    self.sampleRate = sampleRate
    // As the browser sizes it — the longest delay, rounded up, and a render quantum more — and it
    // has to be, because the length takes part in single-precision arithmetic below.
    length = Int((maximumSeconds * sampleRate).rounded(.up)) + 128
    buffer = .allocate(capacity: length)
    buffer.initialize(repeating: 0, count: length)
  }

  deinit {
    buffer.deallocate()
  }

  /// What went in `seconds` ago, on a straight line between the two samples either side.
  /// Read before `write` for the same frame.
  ///
  /// The position is worked out in single precision, as the browser works it out — and at these
  /// magnitudes a 32-bit float resolves only to a sixty-fourth of a frame or so. A delay of
  /// 17142.857 frames is therefore read at 17142.859, and the echo of an impulse comes back as
  /// 9/64 and 55/64 of it, exactly. It is a timing error of a few billionths of a second, and it
  /// is what the reference does, so an echo compared sample for sample has to do it too.
  @_noAllocation
  public func read(secondsAgo seconds: Float, inALoop: Bool) -> Float {
    var frames = seconds * Float(sampleRate)
    if inALoop { frames = max(Float(Self.minimumFramesInALoop), frames) }
    frames = min(frames, Float(length - 1))

    var position = Float(writeIndex + length) - frames
    if position >= Float(length) { position -= Float(length) }
    let index = min(length - 1, Int(position))
    let next = index + 1 == length ? 0 : index + 1
    let fraction = position - Float(index)
    return (1 - fraction) * buffer[index] + fraction * buffer[next]
  }

  @_noAllocation
  public mutating func write(_ sample: Float) {
    buffer[writeIndex] = sample
    writeIndex = writeIndex + 1 == length ? 0 : writeIndex + 1
  }
}
