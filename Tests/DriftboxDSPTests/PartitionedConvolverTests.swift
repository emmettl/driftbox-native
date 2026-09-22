import DriftboxDSP
import Testing

struct PartitionedConvolverTests {
  /// Against the whole-signal transform, on a response several partitions long with a sharp
  /// start, and an input with a click in it: the same answer, within single precision.
  @Test func matchesWholeSignalConvolution() {
    var random = SeededRandom(seed: 7)
    let response = (0..<1000).map { Float(random.next() * 2 - 1) * Float(1 - Double($0) / 1000) }
    let input = (0..<3000).map { index -> Float in
      index == 5 ? 1 : index > 300 && index < 900 ? Float(random.next() * 0.2 - 0.1) : 0
    }
    let expected = Convolution.convolve(input, with: response)

    var convolver = PartitionedConvolver(response: response, block: 128)
    #expect(convolver.partitions == 8)
    var worst: Float = 0
    var peak: Float = 0
    for (index, sample) in input.enumerated() {
      let out = convolver.process(sample)
      worst = max(worst, abs(out - expected[index]))
      peak = max(peak, abs(expected[index]))
    }
    #expect(peak > 0.5)
    #expect(worst < peak * 1e-5, "worst \(worst) against a peak of \(peak)")
  }

  @Test func hasNoLatency() {
    var convolver = PartitionedConvolver(response: [1, 0, 0, 0.5], block: 4)
    var out: [Float] = []
    for frame in 0..<12 { out.append(convolver.process(frame == 0 ? 1 : 0)) }
    #expect(out[0] == 1 && out[1] == 0 && out[2] == 0 && out[3] == 0.5 && out[4] == 0)
  }

  /// Two stages give the one-stage answer, on a response long enough to have a tail.
  @Test func theTwoStageReverbMatchesOneStage() {
    var random = SeededRandom(seed: 11)
    let response = (0..<5000).map { Float(random.next() * 2 - 1) * Float(1 - Double($0) / 5000) }
    let input = (0..<9000).map { index -> Float in
      index == 3 ? 1 : index > 100 && index < 700 ? Float(random.next() * 0.2 - 0.1) : 0
    }
    var one = PartitionedConvolver(response: response, block: 128)
    var two = Reverb(response: response, block: 128)
    var worst: Float = 0
    var peak: Float = 0
    for sample in input {
      let a = one.process(sample)
      let b = two.process(sample)
      worst = max(worst, abs(a - b))
      peak = max(peak, abs(a))
    }
    #expect(peak > 0.5)
    #expect(worst < peak * 1e-5, "worst \(worst) against a peak of \(peak)")
  }
}
