import ConformanceSupport
import DriftboxDSP
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("shaper.json").path)

struct WaveShaperTests {
  struct Case: Decodable {
    let name: String
    let oversample: Bool
    let curve: [Float]
    let input: String
    let output: String
  }

  static func floats(_ file: String) throws -> [Float] {
    try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
      (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
  }

  /// The browser's waveshaper given a curve that does nothing, so that what comes out is its
  /// oversampler alone: an impulse for the response itself, a sine to check it under load.
  /// Needs `emit-audio.mjs` to have run.
  @Test(.enabled(if: isGenerated))
  func theOversamplerIsTheBrowsers() throws {
    let cases = try JSONDecoder().decode(
      [Case].self, from: Data(contentsOf: generated.appendingPathComponent("shaper.json")))
    #expect(cases.count == 4)

    for test in cases {
      let input = try Self.floats(test.input)
      let expected = try Self.floats(test.output)
      var shaper = WaveShaper(curve: test.curve, oversamples: test.oversample)
      var worst: Float = 0
      for (index, sample) in input.enumerated() {
        worst = max(worst, abs(shaper.process(sample) - expected[index]))
      }
      // Single-precision filters summed in a different order: a few steps of a float.
      #expect(worst < 1e-6, "\(test.name) differs by \(worst)")
    }
  }

  @Test func oversamplingDelaysByAHundredAndTwentyEightFrames() {
    var shaper = WaveShaper(curve: [-1, 1], oversamples: true)
    #expect(shaper.latency == 128)
    var peakAt = 0
    var peak: Float = 0
    for frame in 0..<512 {
      let output = abs(shaper.process(frame == 0 ? 1 : 0))
      if output > peak {
        peak = output
        peakAt = frame
      }
    }
    #expect(peakAt == 128)
  }

  @Test func theCurveIsReadWithStraightLines() {
    var shaper = WaveShaper(curve: [-1, 0, 0.5], oversamples: false)
    #expect(shaper.process(-1) == -1)
    #expect(shaper.process(0) == 0)
    #expect(shaper.process(1) == 0.5)
    #expect(shaper.process(-0.5) == -0.5)
    #expect(shaper.process(0.5) == 0.25)
    #expect(shaper.process(3) == 0.5)
    #expect(shaper.process(-3) == -1)
  }
}
