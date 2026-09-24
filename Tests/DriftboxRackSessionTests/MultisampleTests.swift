import ConformanceSupport
import Foundation
import Testing

@testable import DriftboxRackSession

/// A set of recordings mapping itself onto a Multisampler, as the reference maps it: the note and
/// velocity every name implies, and the zones every set is given.
struct MultisampleTests {
  struct Fixture: Decodable {
    struct Zone: Decodable {
      let root, low, high: Int
      let velocityLow, velocityHigh, loopStart, loopEnd, sampleRate: Double
      let loop: Bool
    }
    let parsed: [[Parsed]]
    let sets: [[String]]
    let zones: [[Zone]]
    let noteNames: [String]
  }

  enum Parsed: Decodable {
    case text(String)
    case number(Double)
    case none

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .none
      } else if let number = try? container.decode(Double.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var text: String { if case .text(let value) = self { value } else { "" } }
  }

  static func fixture() throws -> Fixture {
    try JSONDecoder().decode(Fixture.self, from: Fixtures.data("rack/multisample.json"))
  }

  @Test func everyNameMeansWhatItMeansToTheReference() throws {
    let parsed = try Self.fixture().parsed
    #expect(parsed.count > 25)
    for row in parsed {
      let name = row[0].text
      #expect(Multisample.note(name).map(Double.init) == row[1].number, "\(name) note")
      #expect(Multisample.velocity(name) == row[2].number, "\(name) velocity")
    }
  }

  @Test func everySetIsMappedAsTheReferenceMapsIt() throws {
    let fixture = try Self.fixture()
    for (set, expected) in zip(fixture.sets, fixture.zones) {
      let zones = Multisample.zones(names: set, sampleRate: 48000)
      #expect(zones.count == expected.count)
      for (zone, want) in zip(zones, expected) {
        let notes: [Int] = [zone.root, zone.low, zone.high]
        let wanted: [Int] = [want.root, want.low, want.high]
        #expect(notes == wanted, "\(set)")
        #expect(zone.velocityLow == want.velocityLow && zone.velocityHigh == want.velocityHigh, "\(set)")
        #expect(zone.loopStart == want.loopStart && zone.loopEnd == want.loopEnd && zone.loop == want.loop)
        #expect(zone.sampleRate == want.sampleRate)
      }
      #expect(MultisampleZone.unpack(MultisampleZone.pack(zones)) == zones)
    }
    #expect((0..<128).map(Multisample.noteName) == fixture.noteNames)
  }
}
