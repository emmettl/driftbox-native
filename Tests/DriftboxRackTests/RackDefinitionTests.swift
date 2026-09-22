import ConformanceSupport
import DriftboxDocument
import DriftboxRack
import Testing

/// Every module definition against the reference's: a patch names modules, ports and params, so
/// these are the file format, and a knob with the wrong range is a different sound from a saved
/// patch even when every render case passes.
struct RackDefinitionTests {
  /// The reference's modules this build does not have yet, each for a stated reason.
  static let notYet: Set<String> = [
    // The groovebox as a rack module: the engine behind a faceplate, which comes with the host.
    "groovebox",
    // The two filters, being ported.
    "alligator", "vocoder",
  ]

  @Test func everyDefinitionIsTheReferences() throws {
    let modules = try #require(JSONValue(parsing: try Fixtures.text("rack/modules.json"))?.array)
    var missing: [String] = []
    for module in modules.compactMap(\.object) {
      let type = try #require(module["type"]?.string)
      guard let def = RackModules.registry[type] else {
        if !Self.notYet.contains(type) { missing.append(type) }
        continue
      }
      #expect(!Self.notYet.contains(type), "\(type) is here: take it off the list")
      #expect(def.version == Int(module["version"]?.finite ?? -1), "\(type) version")
      #expect(def.name == module["name"]?.string, "\(type) name")
      func ports(_ key: String) -> [(String, Bool)] {
        (module[key]?.array ?? []).compactMap(\.object).map { ($0["id"]?.string ?? "", $0["stereo"]?.bool ?? false) }
      }
      #expect(def.inlets.map(\.id) == ports("inlets").map(\.0), "\(type) inlets")
      #expect(def.inlets.map(\.stereo) == ports("inlets").map(\.1), "\(type) stereo inlets")
      #expect(def.outlets.map(\.id) == ports("outlets").map(\.0), "\(type) outlets")
      #expect(def.outlets.map(\.stereo) == ports("outlets").map(\.1), "\(type) stereo outlets")
      let params = (module["params"]?.array ?? []).compactMap(\.object)
      #expect(def.params.map(\.id) == params.compactMap { $0["id"]?.string }, "\(type) params")
      for (mine, theirs) in zip(def.params, params) {
        #expect(mine.min == theirs["min"]?.finite, "\(type).\(mine.id) min")
        #expect(mine.max == theirs["max"]?.finite, "\(type).\(mine.id) max")
        #expect(mine.defaultValue == theirs["default"]?.finite, "\(type).\(mine.id) default")
        #expect(mine.stepped == theirs["stepped"]?.bool, "\(type).\(mine.id) stepped")
        #expect(mine.hidden == theirs["hidden"]?.bool, "\(type).\(mine.id) hidden")
      }
      #expect(def.poly == module["poly"]?.bool, "\(type) poly")
      #expect(def.terminal == module["terminal"]?.bool, "\(type) terminal")
      #expect(def.voiceExpansion == module["voiceExpansion"]?.finite.map(Int.init), "\(type) expansion")
      #expect(def.voiceCollector == module["voiceCollector"]?.bool, "\(type) collector")
    }
    #expect(missing.isEmpty, "not ported and not on the list: \(missing)")
    #expect(RackModules.all.count == modules.count - Self.notYet.count)
  }
}
