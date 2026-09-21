/// A band-limited oscillator shape, built the way the browser builds its `OscillatorNode`'s.
///
/// A square or a triangle drawn naively has harmonics all the way up, and the ones above half the
/// sample rate fold back down as aliasing. The browser's answer is a bank of wavetables, each one
/// the shape's Fourier series cut off at a different harmonic: three tables to the octave, the
/// oscillator reading from the two that bracket its current pitch and cross-fading between them.
///
/// There are other ways to band-limit an oscillator and some are cheaper. This one is here because
/// the songs were mixed through it. Six detuned squares through a band-pass is what an 808 hat
/// *is* in the reference, and where each square's series stops is part of that sound. So the
/// construction follows Chromium's `PeriodicWave` step for step: the table size, the ranges, how
/// many partials each keeps, and the one normalisation — by the peak of the fullest table, Gibbs
/// overshoot included, which is why a square comes out at about 0.85 and not 1.
public struct WaveTable: Sendable {
  public enum Shape: Sendable {
    case sine, square, sawtooth, triangle
  }

  public let sampleRate: Double
  let size: Int
  /// Every range end to end, from the most partials to the fewest, `size` samples each — one flat
  /// array, so reading it on the render path touches no reference counts. Single precision, as
  /// the browser's are.
  let tables: [Float]
  let ranges: Int
  let lowestFundamental: Double
  /// Table samples per output sample, per Hz.
  let rateScale: Double

  static let rangesPerOctave = 3.0

  public init(shape: Shape, sampleRate: Double) {
    self.sampleRate = sampleRate
    let size = sampleRate <= 24000 ? 2048 : sampleRate <= 88200 ? 4096 : 16384
    self.size = size
    let half = size / 2
    let maximumPartials = half
    lowestFundamental = sampleRate / 2 / Double(maximumPartials)
    rateScale = Double(size) / sampleRate

    // The sine coefficients of each shape's series. There are no cosine terms in any of them.
    var series = [Double](repeating: 0, count: half)
    for n in 1..<half {
      let piFactor = 2 / (Double(n) * Double.pi)
      let odd = n & 1 == 1
      switch shape {
      case .sine: series[n] = n == 1 ? 1 : 0
      case .square: series[n] = odd ? 2 * piFactor : 0
      case .sawtooth: series[n] = piFactor * (odd ? 1 : -1)
      case .triangle: series[n] = odd ? 2 * piFactor * piFactor * (((n - 1) >> 1) & 1 == 1 ? -1 : 1) : 0
      }
    }

    let ranges = Int((Self.rangesPerOctave * log2(Double(size))).rounded())
    self.ranges = ranges
    var tables: [Float] = []
    tables.reserveCapacity(ranges * size)
    var normalisation = 1.0
    for range in 0..<ranges {
      // Each range up keeps a third of an octave fewer partials than the last.
      let partials = Int(dbPow(2, -Double(range) / Self.rangesPerOctave) * Double(maximumPartials))

      // Σ bₙ·sin(2πnk/N), as a conjugate-symmetric spectrum.
      var real = [Double](repeating: 0, count: size)
      var imaginary = [Double](repeating: 0, count: size)
      for n in 1..<half where n <= partials {
        imaginary[n] = -series[n] / 2
        imaginary[size - n] = series[n] / 2
      }
      FFT.inverse(real: &real, imaginary: &imaginary)

      if range == 0 {
        let peak = real.reduce(0) { max($0, abs($1)) }
        if peak > 0 { normalisation = 1 / peak }
      }
      for value in real { tables.append(Float(value * normalisation)) }
    }
    self.tables = tables
  }

  /// Lends the tables to `body` as a `Reader`, which is what the render path uses.
  ///
  /// An array cannot be read from a function marked `@_noAllocation` — touching one moves a
  /// reference count — so the tables are owned here, as an array, and read through a pointer that
  /// is only good for the length of the call. Borrow once per block, not once per sample.
  public func withReader<Result>(_ body: (Reader) -> Result) -> Result {
    tables.withUnsafeBufferPointer { buffer in
      body(
        Reader(
          tables: buffer.baseAddress!, size: size, ranges: ranges, lowestFundamental: lowestFundamental,
          rateScale: rateScale))
    }
  }

  public struct Reader {
    let tables: UnsafePointer<Float>
    let size: Int
    let ranges: Int
    let lowestFundamental: Double
    let rateScale: Double

    /// One sample at `phase` table positions, for an oscillator currently at `frequency`.
    ///
    /// Straight lines both ways: between neighbouring table samples, and between the two tables
    /// that bracket the pitch. (The browser switches to a higher-order interpolation only below a
    /// few hertz, where a drum voice never is.)
    @_noAllocation
    public func sample(at phase: Double, frequency: Double) -> Double {
      let ratio = frequency > 0 ? abs(frequency) / lowestFundamental : 0.5
      // One range early, so partials are dropped just before they would alias, not just after.
      var pitchRange = 1 + log2(ratio) * WaveTable.rangesPerOctave
      pitchRange = max(0, min(Double(ranges - 1), pitchRange))
      let fuller = Int(pitchRange)
      let sparser = min(fuller + 1, ranges - 1)
      let blend = pitchRange - Double(fuller)

      let index = Int(phase)
      let next = (index + 1) & (size - 1)
      let fraction = phase - Double(index)
      let high = tables + fuller * size
      let low = tables + sparser * size
      let fromFuller = (1 - fraction) * Double(high[index]) + fraction * Double(high[next])
      let fromSparser = (1 - fraction) * Double(low[index]) + fraction * Double(low[next])
      return (1 - blend) * fromFuller + blend * fromSparser
    }

    /// Where `phase` is one output sample later at `frequency`, wrapped into the table.
    ///
    /// The step is a single-precision product, because the browser's is: its parameters are
    /// 32-bit floats, and so is the table-samples-per-hertz it multiplies them by. The rounding is
    /// a pitch error of a few parts in a hundred million — nothing — but it is *the same* pitch
    /// error, and over a cowbell's length matching it is the difference between -85dB and -106dB
    /// of agreement. The position itself accumulates in double precision; trying it in single, to
    /// see whether the browser did, made the match 30dB worse.
    @_noAllocation
    public func advance(_ phase: Double, frequency: Double) -> Double {
      var next = phase + Double(Float(frequency) * Float(rateScale))
      let size = Double(size)
      if next >= size { next -= size * Double(Int(next / size)) }
      if next < 0 { next += size }
      return next
    }
  }
}

/// Base-2 logarithm by way of the two functions already vouched for.
@_noAllocation
func log2(_ value: Double) -> Double {
  dbLog(value) / 0.693147180559945309417232121458
}
