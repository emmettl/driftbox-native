import DriftboxDocument
import DriftboxHost
import DriftboxRack
import Foundation
import Testing

@testable import DriftboxRackSession

/// What the rack asks of a platform: somewhere to sound, plug-ins to make, and word of every save.
@MainActor
struct RackPortsTests {
  /// Somewhere to play through that keeps count of what it was given.
  final class Speakers: AudioRouting {
    var chosen: String?
    var devices: [AudioDevice] = []
    var current: AudioDevice?
    var systemDefault: AudioDevice?
    var error: String?
    var onChange: (() -> Void)?
    var sampleRate: Double { 48000 }
    var latency: Double { 0 }
    var attached: [UnsafeMutableRawPointer] = []
    func attach(_ source: RenderSource) { attached.append(source.context) }
    func detach(_ context: UnsafeMutableRawPointer) { attached.removeAll { $0 == context } }
  }

  /// A plug-in that plays silence, and whose settings are whatever a test says.
  final class Unit: RackPluginUnit {
    var latency: Double { 0.01 }
    var savedState: String? = "first"
    var onChange: ((UInt64?) -> Void)?
    /// A cutoff at a quarter of its range and a resonance at a half, and where each macro points.
    var parameters = [
      "cutoff": RackPluginParameter(key: "cutoff", name: "Cutoff", address: 1, fraction: 0.25),
      "resonance": RackPluginParameter(key: "resonance", name: "Resonance", address: 2, fraction: 0.5),
    ]
    var mapped: [String?] = [nil, nil, nil, nil]
    func map(_ slot: Int, to key: String?) { mapped[slot] = key }
    var closed = false
    var external: RackExternal {
      RackExternal(
        render: { _, _, _, _, _, _, _, _, _, _, _ in }, context: Unmanaged.passUnretained(self).toOpaque(),
        owner: self)
    }
    func close() { closed = true }
  }

  /// Plug-ins by id: a unit for `good`, none for `gone`, and one that will not play for `mono`.
  final class Plugins: RackPluginHosting {
    var made: [Unit] = []
    func make(_ reference: PluginReference, sampleRate: Double) async throws -> any RackPluginUnit {
      switch reference.id {
      case "gone": throw RackPluginFailure.missing
      case "mono": throw RackPluginFailure.format
      default:
        let unit = Unit()
        made.append(unit)
        return unit
      }
    }
  }

  static func effect(_ id: String) -> PatchModule {
    var module = PatchModule(id: id, type: "plugin")
    module.plugin = PluginReference(format: "test", id: id, name: id.capitalized, vendor: "Tests")
    return module
  }

  /// Given somewhere to sound, the rack plays through it at once, and lets go of it when closed.
  @Test func itSoundsWhereItIsGiven() {
    let speakers = Speakers()
    let rack = RackSession(audio: speakers)
    #expect(rack.live)
    #expect(speakers.attached == [rack.host.renderSource.context])
    rack.close()
    #expect(speakers.attached.isEmpty)
    #expect(!RackSession().live, "and with nowhere to sound, is not live")
  }

  /// A plug-in module gets a unit from the platform, or says why it has none; a unit changed has
  /// its settings in the patch at the next save; a module that goes lets its unit go.
  @Test func pluginsComeFromThePlatform() async throws {
    let plugins = Plugins()
    let rack = RackSession(plugins: plugins)
    rack.open(
      Patch(modules: [Self.effect("good"), Self.effect("gone"), Self.effect("mono")], cables: []), name: "FX")
    #expect(rack.plugins["good"] == .loading)
    await rack.pluginsReady()
    #expect(rack.plugins["good"] == .ready(latency: 0.01))
    #expect(rack.plugins["gone"] == .missing)
    #expect(rack.plugins["mono"] == .failed("It will not play in stereo at 48000 Hz"))

    let unit = try #require(plugins.made.first)
    unit.savedState = "turned"
    unit.onChange?(nil)
    rack.setBypassed("gone", true)
    #expect(rack.patch.modules.first { $0.id == "good" }?.plugin?.state == "turned")

    rack.remove("good")
    #expect(unit.closed && rack.plugins["good"] == nil)
    #expect(RackSession().plugins.isEmpty)
    let alone = RackSession()
    alone.open(Patch(modules: [Self.effect("good")], cables: []), name: "FX")
    #expect(alone.plugins["good"] == .missing, "with no platform to make it, it is missing")
  }

  /// A macro maps onto one of its unit's params, starting where the param is, as one step of undo;
  /// or learns the next param moved, but not one another macro already turns. The unit is told
  /// where each points, again after an undo.
  @Test func macrosMapOntoAUnitsParams() async throws {
    let plugins = Plugins()
    let rack = RackSession(plugins: plugins)
    rack.open(Patch(modules: [Self.effect("good")], cables: []), name: "FX")
    await rack.pluginsReady()
    let unit = try #require(plugins.made.first)

    rack.mapMacro("good", 1, to: "cutoff")
    let module = try #require(rack.patch.modules.first)
    #expect(module.plugin?.controls == [PluginControl(macro: 1, key: "cutoff", name: "Cutoff")])
    #expect(module.params["macro1"] == 0.25, "the knob where the param is")
    #expect(unit.mapped == ["cutoff", nil, nil, nil])
    #expect(rack.undoTitle == "Undo Map Macro 1")
    #expect(rack.macroParameter("good", 1)?.parameter?.name == "Cutoff")

    rack.learnMacro("good", 2)
    unit.onChange?(1)
    #expect(rack.learning?.macro == 2, "the cutoff is macro 1's, so not learnt")
    unit.onChange?(2)
    #expect(rack.learning == nil)
    #expect(unit.mapped == ["cutoff", "resonance", nil, nil])

    rack.undo()
    #expect(unit.mapped == ["cutoff", nil, nil, nil], "undone, the unit is told again")
    rack.mapMacro("good", 1, to: nil)
    #expect(rack.patch.modules.first?.plugin?.controls.isEmpty == true)
    #expect(rack.undoTitle == "Undo Unmap Macro 1")
  }

  /// Every save is told, as a document and a name: what a platform keeps elsewhere too.
  @Test func aSaveIsTold() {
    let rack = RackSession()
    var saved: [(String, String)] = []
    rack.onSave = { saved.append(($0, $1)) }
    rack.open(Patch(modules: [PatchModule(id: "osc", type: "vco")], cables: []), name: "One")
    #expect(saved.last?.1 == "One")
    #expect(saved.last.flatMap { PatchCodec.decode($0.0) }?.modules.map(\.id) == ["osc"])
  }
}
