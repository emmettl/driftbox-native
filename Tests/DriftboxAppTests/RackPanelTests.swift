#if canImport(AVFoundation)
  import ConformanceSupport
  import DriftboxDocument
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The rack's panels against the reference's own geometry: every module's size, every patch's
  /// placements, jacks and drop targets, and every cable's sag, seed, period, swing and curve, as
  /// `layout.ts`, the faceplate table and `cable.ts` work them out. All of it is arithmetic, so
  /// all of it is held exactly — the curve's text to the tenth it is rounded to.
  @MainActor
  struct RackPanelTests {
    struct Panels: Decodable {
      struct Module: Decodable {
        let type: String
        let span: Int
        let rows: Int
        let summary: String
        let jackRows: Int
      }
      struct Placement: Decodable {
        let id: String
        let span, column, row, rows: Int
        let x, y, width, height: Double
      }
      struct Jack: Decodable {
        let module, port, kind: String
        let stereo: Bool
        let x, y: Double
      }
      struct Cable: Decodable {
        let from, to: [String]
        let drawn: Bool
        let key: String?
        let seed, sag, period: Double?
        let swing: [[Double]]?
        let path: String?
      }
      struct Patch: Decodable {
        let name: String
        let rows: Int
        let height: Double
        let placements: [Placement]
        let jacks: [Jack]
        let cables: [Cable]
        let drops: [Int]
      }
      let modules: [Module]
      let patches: [Patch]
    }

    nonisolated static let panels: Panels? = {
      guard let data = try? Fixtures.data("rack/panels.json") else { return nil }
      return try? JSONDecoder().decode(Panels.self, from: data)
    }()

    nonisolated static let names = panels?.patches.map(\.name) ?? []

    /// The patch a fixture was made from, through the codec as the app would open it.
    static func patch(_ name: String) throws -> Patch {
      struct Document: Decodable {
        let name: String
        let input: String
      }
      let documents = try JSONDecoder().decode([Document].self, from: Fixtures.data("rack/patches.json"))
      let input = try #require(documents.first { $0.name == name }?.input)
      return try #require(PatchCodec.decode(input))
    }

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(1, abs(b)) }

    @Test func everyModuleIsTheReferencesSize() throws {
      let panels = try #require(Self.panels)
      #expect(panels.modules.count >= 48)
      for module in panels.modules {
        let size = RackLayout.size(of: module.type)
        #expect(size.span == module.span, "\(module.type) span")
        #expect(size.rows == module.rows, "\(module.type) rows")
        // The groovebox is not in this build; the rest are, and their words and jacks agree.
        guard let def = RackModules.registry[module.type] else { continue }
        #expect(RackLayout.portSummary(def) == module.summary, "\(module.type)")
        #expect(RackLayout.rowsForJacks(def) == module.jackRows, "\(module.type)")
      }
    }

    @Test(arguments: names)
    func everyPatchIsLaidOutAsTheReferenceLaysItOut(name: String) throws {
      let fixture = try #require(Self.panels?.patches.first { $0.name == name })
      let patch = try Self.patch(name)
      let layout = RackLayout.layout(patch.modules)
      #expect(layout.rows == fixture.rows)
      #expect(layout.height == fixture.height)
      #expect(layout.placements.count == fixture.placements.count)
      for (placement, expected) in zip(layout.placements, fixture.placements) {
        #expect(placement.id == expected.id)
        let slots: [Int] = [placement.span, placement.column, placement.row, placement.rows]
        let expectedSlots: [Int] = [expected.span, expected.column, expected.row, expected.rows]
        #expect(slots == expectedSlots, "\(placement.id)")
        let frame: [Double] = [placement.x, placement.y, placement.width, placement.height]
        let expectedFrame: [Double] = [expected.x, expected.y, expected.width, expected.height]
        #expect(frame == expectedFrame, "\(placement.id)")
      }

      // The groovebox's jacks are the reference's alone: it is not in this build.
      let known = Set(patch.modules.filter { RackModules.registry[$0.type] != nil }.map(\.id))
      let expectedJacks = fixture.jacks.filter { known.contains($0.module) }
      let jacks = RackLayout.jacks(layout.placements)
      #expect(jacks.count == expectedJacks.count)
      for (jack, expected) in zip(jacks, expectedJacks) {
        #expect(
          jack.module == expected.module && jack.port == expected.port, "\(expected.module).\(expected.port)")
        let kind = jack.kind == .inlet ? "in" : "out"
        #expect(kind == expected.kind)
        #expect(jack.stereo == expected.stereo)
        #expect(jack.x == expected.x && jack.y == expected.y, "\(expected.module).\(expected.port)")
      }

      // Every point of a grid over the rack, dropped on.
      var drops: [Int] = []
      var y = -15.0
      while y <= layout.height + 15 {
        var x = 10.0
        while x < layout.width {
          drops.append(RackLayout.dropIndex(layout.placements, at: CGPoint(x: x, y: y)))
          x += 115
        }
        y += 30
      }
      #expect(drops == fixture.drops)
    }

    @Test(arguments: names)
    func cablesHangAndSwingAsTheReferencesDo(name: String) throws {
      let fixture = try #require(Self.panels?.patches.first { $0.name == name })
      let patch = try Self.patch(name)
      let jacks = RackLayout.jacks(RackLayout.layout(patch.modules).placements)
      for expected in fixture.cables where expected.drawn {
        guard
          let from = RackLayout.jack(
            in: jacks, module: expected.from[0], port: expected.from[1], kind: .outlet),
          let to = RackLayout.jack(in: jacks, module: expected.to[0], port: expected.to[1], kind: .inlet)
        else {
          // Only a groovebox's cables have an end this build does not draw.
          #expect(
            [expected.from[0], expected.to[0]].contains { id in
              patch.modules.first { $0.id == id }.map { RackModules.registry[$0.type] == nil } == true
            }, "\(expected.key ?? "")")
          continue
        }
        let key = Cable.key(from: (expected.from[0], expected.from[1]), to: (expected.to[0], expected.to[1]))
        #expect(key == expected.key)
        let seed = Cable.seed(key)
        #expect(seed == expected.seed, "\(key)")
        #expect(Self.close(Cable.sag(from.point, to.point), try #require(expected.sag)), "\(key)")
        #expect(
          Self.close(Cable.period(from.point, to.point, seed: seed), try #require(expected.period)), "\(key)")
        if let swing = expected.swing {
          for (index, direction) in [1.0, -1.0].enumerated() {
            for (step, angle) in swing[index].enumerated() {
              let ours = Cable.swing(
                Double(step) * 100 + 30, from.point, to.point, direction: direction, seed: seed)
              #expect(abs(ours - angle) <= 1e-12, "\(key) at \(step * 100 + 30)ms")
            }
          }
        }
        // `M x y C c1x c1y, c2x c2y, x y`, each to a tenth, at an angle of 0.4.
        let numbers = try #require(expected.path).split(whereSeparator: { " ,MC".contains($0) }).compactMap {
          Double($0)
        }
        let (c1, c2) = Cable.controls(from.point, to.point, angle: 0.4)
        let ours = [from.x, from.y, c1.x, c1.y, c2.x, c2.y, to.x, to.y]
        #expect(numbers.count == 8)
        for (a, b) in zip(ours, numbers) { #expect(abs(a - b) <= 0.051, "\(key)") }
      }
    }

    /// What the app ships is what the reference exported, not a copy that has drifted from it.
    @Test func theShippedRackFilesAreTheFixtures() throws {
      let resources = Fixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DriftboxApp/Resources")
      #expect(
        try Data(contentsOf: resources.appendingPathComponent("patches.json"))
          == Fixtures.data("rack/catalogue.json"))
      #expect(
        try Data(contentsOf: resources.appendingPathComponent("modules.json"))
          == Fixtures.data("rack/faces.json"))
      let documents = try FileManager.default.contentsOfDirectory(
        at: Fixtures.root.appendingPathComponent("rack/documents"), includingPropertiesForKeys: nil)
      let shipped = try FileManager.default.contentsOfDirectory(
        at: resources.appendingPathComponent("Patches"), includingPropertiesForKeys: nil)
      #expect(Set(documents.map(\.lastPathComponent)) == Set(shipped.map(\.lastPathComponent)))
      for document in documents {
        #expect(
          try Data(contentsOf: document)
            == Data(contentsOf: resources.appendingPathComponent("Patches/\(document.lastPathComponent)")))
      }
      // And the app can read them: every entry opens, and every module has its words.
      #expect(PatchEntry.all.count == documents.count)
      for entry in PatchEntry.all { #expect(entry.load() != nil, "\(entry.id)") }
      // Bar the cards for modules the reference has none of.
      #expect(ModuleFace.all.count - ModuleFace.native.count == Self.panels?.modules.count)
      #expect(Set(ModuleFace.native.map(\.type)) == RackModules.nativeOnly)
    }

    /// Every module's picture draws: the paths parse into something with an extent, including
    /// the ones with arcs in them.
    @Test func everyLogoDraws() {
      for face in ModuleFace.all {
        for d in face.logo?.paths ?? [] {
          let bounds = SVGPath.parse(d).boundingRect
          #expect(bounds.width > 0 || bounds.height > 0, "\(face.type): \(d)")
          // Near its 64 × 40 box: the EQ's own strokes run a little past the bottom of it.
          #expect(
            bounds.minX >= -6 && bounds.maxX <= 70 && bounds.minY >= -6 && bounds.maxY <= 46,
            "\(face.type): \(d)")
        }
      }
    }
  }
#endif
