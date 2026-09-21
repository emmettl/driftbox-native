/// A plain radix-2 Fourier transform, for building wavetables — work done once, off the render
/// path, where clarity matters more than speed.
enum FFT {
  /// In place: `x[k] = Σ X[n] · e^(+2πi·nk/N)`, unscaled. `count` must be a power of two.
  static func inverse(real: inout [Double], imaginary: inout [Double]) {
    let count = real.count
    precondition(count == imaginary.count && count > 0 && count & (count - 1) == 0)

    // Bit reversal.
    var j = 0
    for i in 1..<count {
      var bit = count >> 1
      while j & bit != 0 {
        j ^= bit
        bit >>= 1
      }
      j ^= bit
      if i < j {
        real.swapAt(i, j)
        imaginary.swapAt(i, j)
      }
    }

    var length = 2
    while length <= count {
      let angle = 2 * Double.pi / Double(length)
      let stepReal = dbCos(angle)
      let stepImaginary = dbSin(angle)
      var start = 0
      while start < count {
        var twiddleReal = 1.0
        var twiddleImaginary = 0.0
        for k in 0..<length / 2 {
          let a = start + k
          let b = a + length / 2
          let real2 = real[b] * twiddleReal - imaginary[b] * twiddleImaginary
          let imaginary2 = real[b] * twiddleImaginary + imaginary[b] * twiddleReal
          real[b] = real[a] - real2
          imaginary[b] = imaginary[a] - imaginary2
          real[a] += real2
          imaginary[a] += imaginary2
          let next = twiddleReal * stepReal - twiddleImaginary * stepImaginary
          twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
          twiddleReal = next
        }
        start += length
      }
      length <<= 1
    }
  }
}
