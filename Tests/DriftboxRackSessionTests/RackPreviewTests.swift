import ConformanceSupport
import DriftboxRackSession
import Foundation
import Testing

/// What the Chord Player's and the Arp's faces preview, against the reference's own previews over
/// a grid of settings: every chord, every figure, exactly.
struct RackPreviewTests {
  enum Cell: Decodable {
    case number(Int)
    case text(String)

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Int.self) {
        self = .number(number)
      } else {
        self = .text(try container.decode(String.self))
      }
    }

    var number: Int { if case .number(let value) = self { value } else { 0 } }
    var text: String { if case .text(let value) = self { value } else { "" } }
  }

  struct Previews: Decodable {
    let chords: [[Cell]]
    let figures: [[Cell]]
  }

  static func previews() throws -> Previews {
    try JSONDecoder().decode(Previews.self, from: Fixtures.data("rack/previews.json"))
  }

  @Test func everyChordIsTheReferences() throws {
    let chords = try Self.previews().chords
    #expect(chords.count > 2000)
    let custom: [Double] = [1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1]
    for row in chords {
      let flags = Set(row[4].text.split(separator: "+").map(String.init))
      let scale = row[1].number
      let options = RackPreview.Chord(
        key: row[0].number, scale: scale, custom: scale == 13 ? custom : [], notes: row[2].number,
        inversion: row[3].number, open: flags.contains("open"), octUp: flags.contains("octUp"),
        octDown: flags.contains("octDown"), color: flags.contains("color"), alter: flags.contains("alter"))
      let expected = row[5].text.split(separator: " ").compactMap { Int($0) }
      #expect(RackPreview.chord(options) == expected, "\(row.map { $0.number })")
    }
  }

  @Test func everyFigureIsTheReferences() throws {
    let figures = try Self.previews().figures
    #expect(figures.count > 900)
    for row in figures {
      let steps = RackPreview.arp(
        source: row[0].number, chord: row[1].number, octaves: row[2].number, mode: row[3].number,
        shift: row[4].number, insert: row[5].number)
      let expected = row[6].text
      #expect(
        steps.map { "\($0.label):\($0.octave)" }.joined(separator: " ") == expected,
        "\(row.prefix(6).map { $0.number })")
    }
  }
}
