import DriftboxScenes
import Foundation
import Testing

struct AnalyserTests {
  static func analysed(_ samples: [Float], smoothing: Double = 0) -> Analyser {
    let analyser = Analyser()
    analyser.smoothing = smoothing
    samples.withUnsafeBufferPointer { analyser.update($0) }
    return analyser
  }

  @Test func silenceReadsNothing() {
    let analyser = Self.analysed([Float](repeating: 0, count: Analyser.size))
    #expect(analyser.bytes.allSatisfy { $0 == 0 })
    #expect(analyser.levels() == (0, 0, 0))
  }

  /// A kick's fundamental lands in the bass, a hat's hiss in the highs, and a full-scale sine
  /// reads near the top of the analyser's range, as it does in a browser.
  @Test func tonesLandInTheirBands() {
    func sine(_ hertz: Double) -> [Float] {
      (0..<Analyser.size).map { Float(sin(2 * Double.pi * hertz * Double($0) / 48000)) }
    }
    let low = Self.analysed(sine(60))
    let lowBands = low.bands(8)
    #expect(lowBands[0] > 0.5, "60 Hz is in the lowest band: \(lowBands)")
    #expect(lowBands[7] < 0.05, "and not in the highest")
    #expect(low.bytes.max()! > 240, "a full-scale sine is near 0 dB: \(low.bytes.max()!)")

    // The top band is six hundred bins wide, so one sine averages to little there — but to
    // more than anywhere else.
    let high = Self.analysed(sine(12000))
    let highBands = high.bands(8)
    #expect(
      highBands.firstIndex(of: highBands.max()!) == 7, "12 kHz is loudest in the top band: \(highBands)")
    #expect(highBands[0] < 0.05)
  }

  @Test func smoothingHoldsTheLastReadingAndLetsItGo() {
    let analyser = Analyser()
    analyser.smoothing = 0.75
    let tone = (0..<Analyser.size).map { Float(sin(2 * Double.pi * 200 * Double($0) / 48000)) }
    tone.withUnsafeBufferPointer { analyser.update($0) }
    let loud = analyser.bands(8)[1]
    let silence = [Float](repeating: 0, count: Analyser.size)
    silence.withUnsafeBufferPointer { analyser.update($0) }
    let held = analyser.bands(8)[1]
    #expect(held > 0 && held < loud, "one silent frame only eases it: \(loud) then \(held)")
    for _ in 0..<40 { silence.withUnsafeBufferPointer { analyser.update($0) } }
    #expect(analyser.bands(8)[1] == 0, "and forty let it go")
  }

  @Test func easeSnapsUpAndFallsSlowly() {
    #expect(Analyser.ease(0.2, toward: 0.9, dt: 0.016) == 0.9)
    let fallen = Analyser.ease(0.9, toward: 0.2, dt: 0.016)
    #expect(fallen < 0.9 && fallen > 0.85)
  }
}
