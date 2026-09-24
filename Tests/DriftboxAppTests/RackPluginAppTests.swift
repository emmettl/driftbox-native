#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The plug-in module from the app's side: a unit chosen, made and handed to the host; undone and
  /// redone as a module's choice; its settings kept in the patch as it is changed; and a unit this
  /// Mac lacks kept whole and silent. Apple's AULowpass, which every Mac has.
  @MainActor
  struct RackPluginAppTests {
    static let lowpass = PluginReference(
      format: "audio-unit", id: "aufx lpas appl", name: "AULowpass", vendor: "Apple")

    static func model(memory: UserDefaults? = nil) -> RackModel {
      let model = RackModel(memory: memory)
      model.open(Patch(modules: [], cables: []), name: "Empty")
      return model
    }

    static func cutoff(_ unit: HostedAudioUnit?) -> AUParameter? {
      unit?.unit.parameterTree?.parameter(withAddress: 0)
    }

    @Test func aChosenUnitIsMadeAndPlayed() async throws {
      let model = Self.model()
      let id = try #require(model.add("plugin"))
      #expect(model.plugins[id] == nil, "nothing chosen yet")
      #expect(model.patch.modules.map(\.type) == ["plugin"], "an effect brings no Out of its own")

      model.choosePlugin(id, Self.lowpass)
      #expect(model.plugins[id] == .loading)
      await model.pluginsReady()
      guard case .ready = model.plugins[id] else {
        Issue.record("not ready: \(String(describing: model.plugins[id]))")
        return
      }
      #expect(model.units[id]?.reference.id == "aufx lpas appl")
      #expect(model.host.externalModules == [id])
      #expect(model.undoTitle == "Undo Choose AULowpass")

      // Undone, the module has no unit and is silent; redone, it has one again.
      model.undo()
      #expect(model.plugins[id] == nil)
      #expect(model.units[id] == nil)
      #expect(model.host.externalModules.isEmpty)
      model.redo()
      await model.pluginsReady()
      #expect(model.units[id] != nil)
      #expect(model.host.externalModules == [id])

      // An edit elsewhere keeps the same instance, however the graph is rebuilt.
      let unit = try #require(model.units[id])
      model.add("vco")
      #expect(model.units[id] === unit)

      model.remove(id)
      #expect(model.units[id] == nil)
      #expect(model.host.externalModules.isEmpty)
    }

    /// Set in the unit, kept in the patch soon after, and set the same when the patch is opened again.
    @Test func theUnitsSettingsAreKeptInThePatch() async throws {
      let suite = "rack-plugin-tests-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }
      let model = Self.model(memory: memory)
      let id = try #require(model.add("plugin"))
      model.choosePlugin(id, Self.lowpass)
      await model.pluginsReady()
      try #require(Self.cutoff(model.units[id])).value = 321

      // Heard about through the unit's own parameter tree, and saved once it settles.
      var kept: PluginReference?
      for _ in 0..<40 where kept?.state == nil {
        try await Task.sleep(for: .milliseconds(100))
        kept = memory.string(forKey: RackModel.savedKey).flatMap(PatchCodec.decode)?.modules.first?.plugin
      }
      #expect(kept?.id == "aufx lpas appl")
      #expect(kept?.state != nil)
      #expect(
        model.canUndo && model.undoTitle == "Undo Choose AULowpass", "keeping a unit's state is no edit")

      let again = RackModel(memory: memory)
      await again.pluginsReady()
      #expect(Self.cutoff(again.units[id])?.value == 321)
    }

    /// A unit this Mac does not have: silent, said so, and kept exactly for one that does.
    @Test func aMissingUnitIsKeptWhole() async throws {
      var module = PatchModule(id: "fx", type: "plugin")
      module.plugin = PluginReference(
        format: "audio-unit", id: "aufx zzzz zzzz", name: "Elsewhere", vendor: "Nobody", state: "c3RhdGU=")
      let model = Self.model()
      model.open(Patch(modules: [module], cables: []), name: "Travelled")
      await model.pluginsReady()
      #expect(model.plugins["fx"] == .missing)
      #expect(model.units["fx"] == nil)
      #expect(model.patch.modules[0].plugin == module.plugin)
      #expect(
        PluginFace.detail(module.plugin, .missing) == "Not on this Mac. Kept in the patch, silent here.")

      // As is one named in a way this build cannot read.
      module.plugin?.id = "not three codes"
      model.open(Patch(modules: [module], cables: []), name: "Garbled")
      #expect(model.plugins["fx"] == .missing)
    }

    /// Another patch's units are not this one's, even under the same module id.
    @Test func openingAnotherPatchLetsTheUnitsGo() async throws {
      var module = PatchModule(id: "fx", type: "plugin")
      module.plugin = Self.lowpass
      let model = Self.model()
      model.open(Patch(modules: [module], cables: []), name: "One")
      await model.pluginsReady()
      let first = try #require(model.units["fx"])
      model.open(Patch(modules: [module], cables: []), name: "Two")
      await model.pluginsReady()
      #expect(model.units["fx"] != nil)
      #expect(model.units["fx"] !== first)
    }

    @Test func theCatalogueListsThisMacsEffects() {
      let apple = PluginCatalogue.effects.first { $0.vendor == "Apple" }?.entries.map(\.reference.id) ?? []
      #expect(apple.contains("aufx lpas appl"))
      #expect(apple.contains("aufx dely appl"))
      #expect(!PluginCatalogue.effects.contains { $0.entries.contains { $0.reference.id.hasPrefix("aumu") } })
    }

    @Test func thePickerHasACardForIt() {
      #expect(ModuleFace.shelves.first { $0.name == "Effects" }?.types.contains("plugin") == true)
      #expect(RackLayout.size(of: "plugin") == RackLayout.Size(span: 1, rows: 2))
    }
  }
#endif
