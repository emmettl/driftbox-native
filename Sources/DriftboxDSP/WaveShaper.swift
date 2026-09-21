/// A waveshaper with the Web Audio `WaveShaperNode`'s behaviour: a curve looked up with straight
/// lines between its points, optionally run at twice the sample rate so the harmonics it makes
/// have somewhere to go before they are filtered off, instead of folding back as aliasing.
///
/// The oversampling is the browser's, filter for filter, because its filters are audible: they
/// ring a little either side of a transient, and they **delay the signal by 128 frames**. A 909
/// kick in the reference lands 2.7ms after an 808 kick on the same step, and always has. That
/// delay is part of how the songs were mixed, so it is kept rather than corrected.
///
/// It owns raw storage so that `process` can be allocation-free, and is not copyable, so that the
/// storage has exactly one owner.
public struct WaveShaper: ~Copyable {
  /// Taps in the up-sampler's filter, and half as many again in the down-sampler's.
  static let kernelSize = 128

  let curve: UnsafeMutablePointer<Float>
  let curveCount: Int
  public let oversamples: Bool

  /// Windowed-sinc half-band filters. `up` makes the sample between two input samples; `down` is
  /// the odd taps of a filter twice its length, whose even taps are all zero but the middle one.
  let up: UnsafeMutablePointer<Float>
  let down: UnsafeMutablePointer<Float>
  /// The last `kernelSize` of each: inputs, shaped between-samples, and shaped on-samples.
  let inputs: UnsafeMutablePointer<Float>
  let between: UnsafeMutablePointer<Float>
  let on: UnsafeMutablePointer<Float>
  var cursor = 0

  /// A soft-clipping curve: `tanh`, steeper with `amount`, scaled to pass ±1 through unchanged.
  /// The reference's `driveCurve`, including its quantising of the amount to twentieths so that
  /// one knob position is always one curve.
  public static func driveCurve(amount: Double) -> [Float] {
    let scaled = amount * 20
    let floor = scaled.rounded(.down)
    let quantised = (scaled - floor >= 0.5 ? floor + 1 : floor) / 20
    let k = 1 + quantised * 40
    let samples = 1024
    return (0..<samples).map { index in
      let x = Double(index) / Double(samples - 1) * 2 - 1
      return Float(dbTanh(k * x) / dbTanh(k))
    }
  }

  /// How many frames late the output is.
  public var latency: Int { oversamples ? Self.kernelSize : 0 }

  public init(curve points: [Float], oversamples: Bool) {
    let size = Self.kernelSize
    curveCount = points.count
    curve = .allocate(capacity: max(1, points.count))
    curve.initialize(repeating: 0, count: max(1, points.count))
    for (index, point) in points.enumerated() { curve[index] = point }
    self.oversamples = oversamples

    up = .allocate(capacity: size)
    down = .allocate(capacity: size)
    inputs = .allocate(capacity: size)
    between = .allocate(capacity: size)
    on = .allocate(capacity: size)
    inputs.initialize(repeating: 0, count: size)
    between.initialize(repeating: 0, count: size)
    on.initialize(repeating: 0, count: size)

    // Blackman windows, as the browser's are.
    let alpha = 0.16
    let a0 = 0.5 * (1 - alpha)
    let a1 = 0.5
    let a2 = 0.5 * alpha
    func window(_ x: Double) -> Double {
      a0 - a1 * dbCos(2 * Double.pi * x) + a2 * dbCos(4 * Double.pi * x)
    }
    func sinc(_ s: Double) -> Double { s == 0 ? 1 : dbSin(s) / s }

    // Up: a sinc sampled half a sample off-centre, because it is making the half-way samples.
    for tap in 0..<size {
      let offset = Double(tap) + 0.5
      up[tap] = Float(sinc(Double.pi * (offset - Double(size / 2))) * window(offset / Double(size)))
    }
    // Down: a half-band filter of 2 × size taps, keeping only the odd ones.
    let full = size * 2
    for tap in 0..<size {
      let i = Double(tap * 2 + 1)
      down[tap] = Float(0.5 * sinc(0.5 * Double.pi * (i - Double(full / 2))) * window(i / Double(full)))
    }
  }

  deinit {
    curve.deallocate()
    up.deallocate()
    down.deallocate()
    inputs.deallocate()
    between.deallocate()
    on.deallocate()
  }

  /// The curve at `input`: -1 is its first point, 1 its last, straight lines between.
  @_noAllocation
  func shape(_ input: Float) -> Float {
    guard curveCount > 0 else { return input }
    let position = 0.5 * (input + 1) * Float(curveCount - 1)
    if position < 0 { return curve[0] }
    if position >= Float(curveCount - 1) { return curve[curveCount - 1] }
    let index = Int(position)
    let fraction = position - Float(index)
    return (1 - fraction) * curve[index] + fraction * curve[index + 1]
  }

  @_noAllocation
  public mutating func process(_ input: Float) -> Float {
    guard oversamples else { return shape(input) }
    let size = Self.kernelSize
    let mask = size - 1

    // Up to twice the rate. The on-sample is the input from half a filter ago, passed straight
    // through; the between-sample is the filter over the last `size` inputs.
    inputs[cursor] = input
    var interpolated: Float = 0
    for tap in 0..<size { interpolated += up[tap] * inputs[(cursor - tap) & mask] }
    let delayed = inputs[(cursor - size / 2) & mask]

    // Shape both. Back down: the filter runs over the between-samples up to the previous frame,
    // and its one non-zero even tap, the middle, is half the on-sample from half a filter ago.
    var output: Float = 0
    for tap in 0..<size { output += down[tap] * between[(cursor - 1 - tap) & mask] }
    on[cursor] = shape(delayed)
    between[cursor] = shape(interpolated)
    output += 0.5 * on[(cursor - size / 2) & mask]

    cursor = (cursor + 1) & mask
    return output
  }
}
