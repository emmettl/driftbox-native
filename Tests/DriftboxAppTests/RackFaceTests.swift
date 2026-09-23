#if canImport(AVFoundation)
  import DriftboxRack
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
  }
#endif
