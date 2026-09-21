/// Convolution by way of the frequency domain, for a whole signal at once.
///
/// This is the offline form: it is how a reverb is *checked*, and how a song is rendered to a
/// file. A room three seconds long is 180,000 taps, which no loop can do per sample in real time;
/// the real-time form splits the impulse response into blocks of growing size and transforms
/// each, and gives the same answer.
public enum Convolution {
  /// `signal` convolved with `response`, as long as the two together.
  public static func convolve(_ signal: [Float], with response: [Float]) -> [Float] {
    guard !signal.isEmpty, !response.isEmpty else { return [] }
    let length = signal.count + response.count - 1
    var size = 1
    while size < length { size <<= 1 }

    var signalReal = [Double](repeating: 0, count: size)
    var signalImaginary = [Double](repeating: 0, count: size)
    var responseReal = [Double](repeating: 0, count: size)
    var responseImaginary = [Double](repeating: 0, count: size)
    for (index, sample) in signal.enumerated() { signalReal[index] = Double(sample) }
    for (index, sample) in response.enumerated() { responseReal[index] = Double(sample) }

    // The transform of a real signal is the conjugate of its inverse transform, and the product
    // of two conjugates is the conjugate of the product — so the inverse transform does for both
    // directions, with the conjugate taken once at the end.
    FFT.inverse(real: &signalReal, imaginary: &signalImaginary)
    FFT.inverse(real: &responseReal, imaginary: &responseImaginary)
    for bin in 0..<size {
      let real = signalReal[bin] * responseReal[bin] - signalImaginary[bin] * responseImaginary[bin]
      let imaginary = signalReal[bin] * responseImaginary[bin] + signalImaginary[bin] * responseReal[bin]
      signalReal[bin] = real
      signalImaginary[bin] = -imaginary
    }
    FFT.inverse(real: &signalReal, imaginary: &signalImaginary)
    return (0..<length).map { Float(signalReal[$0] / Double(size)) }
  }
}
