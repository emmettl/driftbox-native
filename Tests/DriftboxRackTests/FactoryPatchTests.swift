import ConformanceSupport
import DriftboxDocument
import DriftboxRack
import Foundation
import Testing

/// Every factory patch the reference ships, played for a second with the transport running at its
/// tempo, through the codec: all its modules working together, as somebody opening it would hear
/// it. The render cases hold each module; these hold the rack.
struct FactoryPatchTests {
  struct Played {
    let id: String
    let blocks: Int
    let tempo: Double
  }

  static func played() throws -> [Played] {
    guard let all = JSONValue(parsing: try Fixtures.text("rack/factory/played.json"))?.array else {
      return []
    }
    return all.compactMap(\.object).compactMap { object in
      guard let id = object["id"]?.string, let blocks = object["blocks"]?.finite,
        let tempo = object["tempo"]?.finite
      else { return nil }
      return Played(id: id, blocks: Int(blocks), tempo: tempo)
    }
  }

  static let ids = (try? played().map(\.id)) ?? []

  @Test func everyPatchLoads() throws {
    #expect(try Self.played().count == 11)
  }

  @Test(arguments: ids)
  func playsAsTheReferenceDoes(id: String) throws {
    let fixture = try #require(try Self.played().first { $0.id == id })
    let documents = try #require(JSONValue(parsing: try Fixtures.text("rack/patches.json"))?.array)
    let text = try #require(
      documents.compactMap(\.object).first { $0["name"]?.string == "factory-\(id)" }?["input"]?.string)
    let patch = try #require(PatchCodec.decode(text))
    let data = try Fixtures.data("rack/factory/\(id).f32")
    let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let frames = fixture.blocks * 128

    let renderer = RackRenderer(sampleRate: 48000, frames: 128)
    renderer.patch = patch
    renderer.setTransport(tempo: fixture.tempo, running: true)
    // The emitter's note, and fifth, on a patch played from a keyboard.
    let keys = patch.modules.first { $0.type == "midi" }?.id
    if let keys {
      renderer.setParam(keys, "note", 48, voice: 0)
      renderer.setParam(keys, "gate", 1, voice: 0)
      if (patch.voices ?? 1) > 1 {
        renderer.setParam(keys, "note", 55, voice: 1)
        renderer.setParam(keys, "gate", 1, voice: 1)
      }
    }
    let early = renderer.render(frames: 250 * 128)
    if let keys { renderer.setParam(keys, "gate", 0) }
    let late = renderer.render(frames: frames - 250 * 128)
    let (left, right) = (early.left + late.left, early.right + late.right)
    var worst: Float = 0
    var loudest: Float = 0
    for index in 0..<frames {
      worst = max(worst, abs(left[index] - expected[index]), abs(right[index] - expected[frames + index]))
      loudest = max(loudest, abs(expected[index]))
    }
    #expect(renderer.notes.allSatisfy { $0.kind != "placeholder" }, "\(id) uses a module this build lacks")
    #expect(worst < 1e-5, "\(id) differs by \(worst) (loudest \(loudest))")
    // Every patch but the one that takes its first bars to arrive is heard.
    if id != "pressure-system" { #expect(loudest > 0.01, "\(id) is silent") }
  }
}
