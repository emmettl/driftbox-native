import Foundation
import Testing

@testable import DriftboxDSP

struct SeededRandomTests {
  struct Stream: Decodable {
    let seed: UInt32
    let first: [UInt32]
  }

  @Test func matchesTheReferenceBitForBit() throws {
    let streams = try JSONDecoder().decode([Stream].self, from: Fixtures.data("prng/xorshift32.json"))
    #expect(!streams.isEmpty)
    for stream in streams {
      var random = SeededRandom(seed: stream.seed)
      let bits = stream.first.map { _ in random.nextBits() }
      #expect(bits == stream.first, "seed \(stream.seed)")
    }
  }

  @Test func floatsAreTheBitsOverTwoToTheThirtyTwo() {
    var a = SeededRandom(seed: 0x909)
    var b = SeededRandom(seed: 0x909)
    for _ in 0..<64 {
      let value = a.next()
      #expect(value == Double(b.nextBits()) / 4_294_967_296)
      #expect(value >= 0 && value < 1)
    }
  }
}
