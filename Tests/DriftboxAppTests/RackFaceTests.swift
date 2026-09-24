#if canImport(AVFoundation)
  import DriftboxRack
  import DriftboxRackSession
  import Testing

  @testable import DriftboxApp

  /// A hand-built face reaches every param a hand could set on its module: one added to the module
  /// and not to the face would otherwise be a knob nobody can turn.
  struct RackFaceTests {
    @Test(arguments: Array(HandBuilt.shows.keys))
    func aHandBuiltFaceReachesEveryParam(type: String) throws {
      let def = try #require(RackModules.registry[type])
      let visible = Set(def.params.filter { !$0.hidden }.map(\.id))
      let shown = try #require(HandBuilt.shows[type])
      #expect(visible.isSubset(of: shown), "\(type) misses \(visible.subtracting(shown).sorted())")
      // And names nothing the module does not have.
      #expect(
        shown.isSubset(of: Set(def.params.map(\.id))),
        "\(type) names \(shown.subtracting(def.params.map(\.id)))")
    }

    /// Every hand-built face here is one the reference sizes by hand too, so the layout already
    /// has room for it.
    @Test func everyHandBuiltFaceIsSizedByTheReferencesTable() {
      for type in HandBuilt.shows.keys { #expect(RackLayout.handBuilt[type] != nil, "\(type)") }
    }

    @Test func theScaleMapIsTheReferencesMask() {
      let augmented: [Double] = [1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1]
      #expect(ScalePlayerFace.mask(13, augmented) == augmented)
      #expect(ScalePlayerFace.mask(13, []) == ScalePlayerFace.mask(0, []))
      #expect(
        (0..<13).map { ScalePlayerFace.mask($0, []).reduce(0, +) } == [
          7, 7, 7, 7, 7, 7, 7, 7, 7, 5, 5, 5, 12,
        ])
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
