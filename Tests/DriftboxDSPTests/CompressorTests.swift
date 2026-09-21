import ConformanceSupport
import DriftboxDSP
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("compressor.json").path)

struct CompressorTests {
  struct Case: Decodable {
    let name: String
    let threshold: Float
    let knee: Float
    let ratio: Float
    let attack: Float
    let release: Float
    let sampleRate: Double
    let inputLeft: String
    let inputRight: String
    let left: String
    let right: String
  }

  static func floats(_ file: String) throws -> [Float] {
    try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
      (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
  }

  /// The browser's compressor alone, on an input made to show its moves. There is no
  /// specification to hold it to, only this. Needs `emit-audio.mjs` to have run.
  @Test(.enabled(if: isGenerated))
  func itIsTheBrowsersCompressor() throws {
    let cases = try JSONDecoder().decode(
      [Case].self, from: Data(contentsOf: generated.appendingPathComponent("compressor.json")))
    #expect(cases.count == 3)

    var report = ""
    for test in cases {
      let inLeft = try Self.floats(test.inputLeft)
      let inRight = try Self.floats(test.inputRight)
      let expectedLeft = try Self.floats(test.left)
      let expectedRight = try Self.floats(test.right)
      var compressor = Compressor(
        .init(
          threshold: test.threshold, knee: test.knee, ratio: test.ratio, attack: test.attack,
          release: test.release),
        sampleRate: test.sampleRate)

      var worst: Float = 0
      var worstAt = 0
      var peak: Float = 0
      for frame in 0..<inLeft.count {
        let out = compressor.process(left: inLeft[frame], right: inRight[frame])
        let difference = max(abs(out.left - expectedLeft[frame]), abs(out.right - expectedRight[frame]))
        if difference > worst {
          worst = difference
          worstAt = frame
        }
        peak = max(peak, abs(expectedLeft[frame]), abs(expectedRight[frame]))
      }
      let decibels = worst > 0 ? 20 * log10(Double(worst / peak)) : -Double.infinity
      report += "\(test.name): \(String(format: "%.1f", decibels))dB, worst at frame \(worstAt)\n"
      // Measured at -125 to -138dB against the arm64 Chrome this was developed on. Against an x64
      // Chrome the harder settings are looser, because the two browsers are: they differ from
      // each other by -136, -114 and -86dB on these three cases, the compressor being single
      // precision throughout and built on `log`, `pow` and `sin` from whichever maths library the
      // platform has. Each bound is the browsers' own disagreement with a little room.
      let bound = test.name == "assertive" ? -82.0 : test.name == "gentle" ? -105.0 : -125.0
      #expect(decibels <= bound, "\(test.name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }

  @Test func itLooksAheadSixMilliseconds() {
    let compressor = Compressor(
      .init(threshold: -14, knee: 8, ratio: 4, attack: 0.004, release: 0.18), sampleRate: 48000)
    #expect(compressor.latency == 288)
  }

  /// Below the threshold nothing is compressed, and everything comes out louder: the makeup gain
  /// is what the curve would do to full scale, undone, to the 0.6.
  @Test func quietSignalsComeOutLouder() {
    var compressor = Compressor(
      .init(threshold: -14, knee: 8, ratio: 4, attack: 0.004, release: 0.18), sampleRate: 48000)
    var peak: Float = 0
    for frame in 0..<48000 {
      let input = 0.05 * Float(sin(Double(frame) * 0.03))
      let out = compressor.process(left: input, right: input)
      if frame > 24000 { peak = max(peak, abs(out.left)) }
    }
    #expect(abs(peak / 0.05 - 1.72) < 0.01)
  }
}
