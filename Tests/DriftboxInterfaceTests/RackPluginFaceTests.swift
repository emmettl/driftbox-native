import DriftboxHost
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Foundation
import Testing

@testable import DriftboxInterface

/// The plug-in modules' front: what it hosts and how it is, a menu to choose another, and its
/// macros, mapped from a menu and named and read in their param's words.
@MainActor
struct RackPluginFaceTests {
  /// A plug-in that plays silence, with a cutoff and a resonance, and words for their values.
  final class Unit: RackPluginUnit {
    var latency: Double { 0.002 }
    var savedState: String? { nil }
    var onChange: ((UInt64?) -> Void)?
    var parameters = [
      "cutoff": RackPluginParameter(key: "cutoff", name: "Cutoff", address: 1, fraction: 0.25),
      "resonance": RackPluginParameter(key: "resonance", name: "Resonance", address: 2, fraction: 0.5),
    ]
    func map(_ slot: Int, to key: String?) {}
    var external: RackExternal {
      RackExternal(
        render: { _, _, _, _, _, _, _, _, _, _, _ in }, context: Unmanaged.passUnretained(self).toOpaque(),
        owner: self)
    }
    func close() {}
    /// The titles of the interfaces it was asked to show.
    var shown: [String] = []
    func showInterface(title: String) { shown.append(title) }
    func display(_ key: String, at fraction: Double) -> String? {
      key == "cutoff" ? "\(Int(fraction * 1000)) Hz" : nil
    }
  }

  /// Two effects and an instrument to choose from; a unit for any of them but `gone`.
  final class Plugins: RackPluginHosting {
    func make(_ reference: PluginReference, sampleRate: Double) async throws -> any RackPluginUnit {
      if reference.id == "GONE" { throw RackPluginFailure.missing }
      return Unit()
    }
    func available() async -> [RackPluginChoice] {
      [
        RackPluginChoice(reference: Self.reference("ECHO", "Echo"), instrument: false),
        RackPluginChoice(reference: Self.reference("VERB", "Verb"), instrument: false),
        RackPluginChoice(reference: Self.reference("SYNTH", "Synth"), instrument: true),
      ]
    }
    static func reference(_ id: String, _ name: String) -> PluginReference {
      PluginReference(format: "vst3", id: id, name: name, vendor: "Acme")
    }
  }

  /// A rack of one plug-in module, its unit made.
  static func rack(_ reference: PluginReference?, type: String = "plugin") async -> RackInterface {
    let rack = RackSession(plugins: Plugins())
    var module = PatchModule(id: "fx", type: type)
    module.plugin = reference
    rack.open(Patch(modules: [module], cables: []), name: "FX")
    await rack.pluginsReady()
    let face = RackInterface(rack: rack)
    face.size = SIMD2(1000, 700)
    return face
  }

  static func face(_ face: RackInterface) throws -> RackStage.Face {
    try #require(face.stage.faces.first { $0.module.id == "fx" })
  }

  /// Press the face's button labelled `label`, and take the menu it asks for.
  static func menu(_ face: RackInterface, _ label: String) throws -> Menu {
    let button = try #require(try Self.face(face).buttons.first { $0.label == label })
    let point = RackInterfaceTests.window(face.stage, RackInterfaceTests.centre(button.frame))
    RackInterfaceTests.press(face, point)
    return try #require(face.takeMenuRequest()).menu
  }

  /// Running, it says so, and how late, and its format; its macros are asleep until mapped, and
  /// mapped from its menu, each is named for its param and says its value in the plug-in's words.
  @Test func aRunningPlugInsMacrosAreMapped() async throws {
    let face = await Self.rack(Plugins.reference("ECHO", "Echo"))
    var front = try Self.face(face)
    #expect(
      front.words == "running" && front.light == true && front.mark == "VST3" && front.name == "Plug-in")
    #expect(front.buttons.map(\.label) == ["Change…", "Open", "Map…"])
    #expect(front.controls.map(\.name) == ["Macro 1", "Macro 2", "Macro 3", "Macro 4"])
    #expect(front.controls.allSatisfy { $0.opacity == 0.5 })
    #expect(
      RackFaces.detail(front.module.plugin, face.rack.plugins["fx"], instrument: false)
        == "Acme · 2.0 ms late")

    let macros = try Self.menu(face, "Map…")
    #expect(macros.items.count == 4)
    #expect(macros.commands.prefix(2).map(\.title) == ["Cutoff", "Resonance"], "by name")
    face.choose("macro.1.cutoff")
    front = try Self.face(face)
    #expect(front.controls[0].name == "Cutoff" && front.controls[0].opacity == 1)
    #expect(front.controls[0].display?(0.5) == "500 Hz")
    #expect(face.rack.patch.modules[0].params["macro1"] == 0.25, "where the param was")

    let again = try Self.menu(face, "Map…")
    #expect(
      again.items.first.map { if case .submenu(let menu) = $0 { menu.title } else { "" } }
        == "Macro 1: Cutoff")
    #expect(face.menuIsChecked("macro.1.cutoff"))
    face.choose("macro.1.unmap")
    #expect(face.rack.macroParameter("fx", 1) == nil)
  }

  /// Its own interface opens from its face, titled for the plug-in and the module; a macro learns the
  /// next param moved there, which opens it too, and says it is waiting until it has one, or stops.
  @Test func itsInterfaceOpensAndAMacroLearnsFromIt() async throws {
    let face = await Self.rack(Plugins.reference("ECHO", "Echo"))
    let unit = try #require(face.rack.units["fx"] as? Unit)
    let open = try #require(try Self.face(face).buttons.first { $0.label == "Open" })
    RackInterfaceTests.press(
      face, RackInterfaceTests.window(face.stage, RackInterfaceTests.centre(open.frame)))
    #expect(unit.shown == ["Echo — fx"])

    _ = try Self.menu(face, "Map…")
    face.choose("macro.2.learn")
    #expect(face.rack.learning?.module == "fx" && face.rack.learning?.macro == 2)
    #expect(unit.shown.count == 2, "opened to learn from")
    #expect(try Self.face(face).controls[1].name == "Learn…")
    _ = try Self.menu(face, "Map…")
    face.choose("macro.2.stop")
    #expect(face.rack.learning == nil)
    #expect(try Self.face(face).controls[1].name == "Macro 2")
  }

  /// Another of its kind is chosen from its own menu, which ticks the one it has, in one step.
  @Test func anotherPlugInIsChosen() async throws {
    let face = await Self.rack(Plugins.reference("ECHO", "Echo"))
    _ = try Self.menu(face, "Change…")
    await face.rack.pluginsFound()
    let menu = try Self.menu(face, "Change…")
    #expect(menu.commands.map(\.title) == ["Echo", "Verb"], "effects alone")
    #expect(face.menuIsChecked("plugin.vst3.ECHO"))
    face.choose("plugin.vst3.VERB")
    #expect(face.rack.patch.modules[0].plugin?.name == "Verb")
    #expect(face.rack.undoTitle == "Undo Choose Verb")
  }

  /// Empty, it asks for one and has nothing to map; missing, it says so; an instrument is named so.
  @Test func whatItHasNotIsSaid() async throws {
    let empty = try Self.face(await Self.rack(nil))
    #expect(empty.words == "empty" && empty.light == false && empty.mark == nil)
    #expect(empty.buttons.map(\.label) == ["Choose…"])

    let missing = await Self.rack(Plugins.reference("GONE", "Gone"))
    #expect(try Self.face(missing).words == "missing")
    #expect(
      RackFaces.detail(try Self.face(missing).module.plugin, .missing, instrument: false)
        == "Not on this machine. Kept in the patch, silent here.")

    let instrument = try Self.face(
      await Self.rack(Plugins.reference("SYNTH", "Synth"), type: "plugin-instrument"))
    #expect(instrument.name == "Instrument")
  }

  /// Where the platform makes no plug-ins, there is nothing to choose from.
  @Test func withNoPlatformThereIsNoChoosing() throws {
    let rack = RackSession()
    rack.open(Patch(modules: [PatchModule(id: "fx", type: "plugin")], cables: []), name: "FX")
    let face = RackInterface(rack: rack)
    face.size = SIMD2(1000, 700)
    let choose = try #require(try Self.face(face).buttons.first)
    #expect(choose.press == nil && choose.opacity < 1)
  }

  /// A long list of params comes in runs, each named from its first to its last.
  @Test func manyParamsComeInRuns() {
    let items = (0..<50).map { MenuItem.command("P\($0)", id: "\($0)") }
    let runs = RackInterface.runs(items, names: (0..<50).map { "P\($0)" })
    #expect(runs.count == 2)
    #expect(
      runs.map { if case .submenu(let menu) = $0 { menu.title } else { "" } } == ["P0 – P29", "P30 – P49"])
    #expect(RackInterface.runs(Array(items.prefix(40)), names: []).count == 40)
  }
}
