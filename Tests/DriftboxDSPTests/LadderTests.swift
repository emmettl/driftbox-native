import Foundation
import Testing

@testable import DriftboxDSP

struct LadderTests {
  @Test func matchesTheReference() throws {
    struct Header: Decodable {
      let sampleRate: Double
      let frames: Int
    }
    let header = try JSONDecoder().decode(Header.self, from: Fixtures.data("dsp/ladder.json"))
    let columns = try Fixtures.doubles("dsp/ladder.f64")
    #expect(columns.count == header.frames * 4)

    var ladder = Ladder(sampleRate: header.sampleRate)
    var worst = 0.0
    var peak = 0.0
    for frame in 0..<header.frames {
      let at = frame * 4
      let out = ladder.process(columns[at], cutoff: columns[at + 1], resonance: columns[at + 2])
      worst = max(worst, abs(out - columns[at + 3]))
      peak = max(peak, abs(columns[at + 3]))
    }

    // The fixture is only worth comparing against if the filter was actually doing something.
    #expect(peak > 0.5)
    // Compared at double precision. See the note on `tolerance`.
    #expect(worst <= Self.tolerance, "worst difference \(worst)")
  }

  /// The arithmetic is identical; `exp` and `tanh` come from two different maths libraries (V8's
  /// and the platform's), which may disagree in the last bit, and the resonant loop feeds that
  /// back. Measured at 1.8e-15 against Apple's libm when this was written, so not bit-exact and not
  /// far off; the bound is that with three orders of headroom, and is still some 200dB below
  /// anything audible.
  static let tolerance = 1e-12
}
