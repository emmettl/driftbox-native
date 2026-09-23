import ConformanceSupport
import DriftboxDocument
import DriftboxRack
import Testing

/// Patches as documents, against what the reference makes of the same text: every factory and
/// song patch it ships, and a set of damaged ones, decoded and encoded again byte for byte — or
/// refused where it refuses.
struct PatchCodecTests {
  struct Case {
    let name: String
    let input: String
    let output: String?
  }

  static func cases() throws -> [Case] {
    guard let all = JSONValue(parsing: try Fixtures.text("rack/patches.json"))?.array else { return [] }
    return all.compactMap(\.object).compactMap { object in
      guard let name = object["name"]?.string, let input = object["input"]?.string else { return nil }
      return Case(name: name, input: input, output: object["output"]?.string)
    }
  }

  static let names = (try? cases().map(\.name)) ?? []

  @Test func everyCaseLoads() throws {
    #expect(try Self.cases().count == 40)
  }

  @Test(arguments: names)
  func repairsAsTheReferenceDoes(name: String) throws {
    let fixture = try #require(try Self.cases().first { $0.name == name })
    let decoded = PatchCodec.decode(fixture.input)
    #expect(decoded.map(PatchCodec.encode) == fixture.output)
  }

  /// A patch survives the round trip whole, in the same order it was written.
  @Test func aRoundTripIsTheSamePatch() throws {
    for fixture in try Self.cases() where fixture.name.hasPrefix("factory-") {
      let patch = try #require(PatchCodec.decode(fixture.input))
      #expect(PatchCodec.decode(PatchCodec.encode(patch)) == patch, "\(fixture.name)")
    }
  }
}
