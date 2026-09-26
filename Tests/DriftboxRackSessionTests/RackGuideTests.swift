import DriftboxRack
import Testing

@testable import DriftboxRackSession

/// A module's guide, assembled as the reference assembles it: from its definition and its card,
/// with the teaching written for the modules that need it.
struct RackGuideTests {
  static func headings(_ guide: RackGuide) -> [String] { guide.parts.map(\.heading) }

  /// Every module has one, whether a guide was written for it or not; sixteen were.
  @Test func everyModuleHasAGuide() {
    for type in RackModules.registry.keys {
      #expect(RackGuide.guide(for: type) != nil, "\(type)")
    }
    #expect(ModuleFace.all.filter { $0.guide != nil }.count == 16)
    #expect(RackGuide.guide(for: "no-such-module") == nil)
  }

  /// A written guide: what it does in its own words, how it works, a first patch, the controls and
  /// what to watch for, under the module's shelf.
  @Test func aWrittenGuideTeaches() throws {
    let guide = try #require(RackGuide.guide(for: "alligator"))
    #expect(guide.title == "Alligator" && guide.trail == "Driftbox / Filters / Module guide")
    #expect(
      Self.headings(guide) == [
        "What it does", "Signal flow", "How it works", "Try this first", "Controls", "Watch for",
      ])
    guard case .prose(let overview) = guide.parts[0].body else {
      Issue.record("no overview")
      return
    }
    #expect(overview.hasPrefix("Alligator splits one sound"))
    guard case .definitions(let concepts) = guide.parts[2].body else {
      Issue.record("no concepts")
      return
    }
    #expect(concepts.first?.term == "The gate inputs are the rhythm")
    guard case .steps(let steps) = guide.parts[3].body else {
      Issue.record("no steps")
      return
    }
    #expect(steps.count == 3)
  }

  /// With none written, the card's line of copy, the signal flow and the controls; and a module with
  /// no inlets says so in words.
  @Test func anUnwrittenGuideIsTheReference() throws {
    let guide = try #require(RackGuide.guide(for: "adsr"))
    #expect(Self.headings(guide) == ["What it does", "Signal flow", "Controls"])
    let face = try #require(ModuleFace.all.first { $0.type == "adsr" })
    #expect(guide.parts[0].body == .prose(face.blurb ?? ""))

    let source = try #require(RackModules.registry.values.first { $0.inlets.isEmpty && !$0.outlets.isEmpty })
    let flow = RackGuide.guide(source, face: nil)
    guard case .flow(let ins, let outs, let noIns, _) = flow.parts[1].body else {
      Issue.record("no flow")
      return
    }
    #expect(ins.isEmpty && !outs.isEmpty && noIns.hasPrefix("None"))
    #expect(flow.trail == "Driftbox / Device / Module guide")
  }

  /// A control's range is its selector's words where it has them, and otherwise from where to where
  /// and where it starts, in numbers as JavaScript writes them.
  @Test func aControlSaysItsRange() {
    let selector = ParamDef("mode", "Mode", min: 0, max: 2, default: 0)
    #expect(RackGuide.range(selector, labels: ["Low", "Band", "High"]) == "Low · Band · High")
    let knob = ParamDef("cutoff", "Cutoff", min: 20, max: 20000, default: 0.5)
    #expect(RackGuide.range(knob, labels: nil) == "20–20000 · starts at 0.5")
  }
}
