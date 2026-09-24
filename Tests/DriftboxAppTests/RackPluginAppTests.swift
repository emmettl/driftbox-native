#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRack
  import DriftboxRackSession
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

    /// A rack hosting the Mac's Audio Units, as the app's does.
    static func model(memory: UserDefaults? = nil) -> RackSession {
      let model = RackSession(plugins: AudioUnitHosting(), memory: memory)
      model.open(Patch(modules: [], cables: []), name: "Empty")
      return model
    }

    /// The Audio Unit a module's plug-in is.
    static func unit(_ model: RackSession, _ id: String) -> HostedAudioUnit? {
      (model.units[id] as? AudioUnitPlugin)?.hosted
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
      #expect(Self.unit(model, id)?.reference.id == "aufx lpas appl")
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
      try #require(Self.cutoff(Self.unit(model, id))).value = 321

      // Heard about through the unit's own parameter tree, and saved once it settles.
      var kept: PluginReference?
      for _ in 0..<40 where kept?.state == nil {
        try await Task.sleep(for: .milliseconds(100))
        kept = memory.string(forKey: RackSession.savedKey).flatMap(PatchCodec.decode)?.modules.first?.plugin
      }
      #expect(kept?.id == "aufx lpas appl")
      #expect(kept?.state != nil)
      #expect(
        model.canUndo && model.undoTitle == "Undo Choose AULowpass", "keeping a unit's state is no edit")

      let again = RackSession(plugins: AudioUnitHosting(), memory: memory)
      await again.pluginsReady()
      #expect(Self.cutoff(Self.unit(again, id))?.value == 321)
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
      await model.pluginsReady()
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

    @Test func theCatalogueListsThisMacsEffectsAndInstruments() {
      let apple = PluginCatalogue.effects.first { $0.vendor == "Apple" }?.entries.map(\.reference.id) ?? []
      #expect(apple.contains("aufx lpas appl"))
      #expect(apple.contains("aufx dely appl"))
      #expect(!PluginCatalogue.effects.contains { $0.entries.contains { $0.reference.id.hasPrefix("aumu") } })
      let instruments = PluginCatalogue.instruments.flatMap(\.entries).map(\.reference.id)
      #expect(instruments.contains("aumu dls  appl"))
      #expect(instruments.allSatisfy { $0.hasPrefix("aumu") })
    }

    // MARK: Macros

    /// A macro mapped from the unit's own params: one step of undo, its knob where the param is,
    /// the host told, and all of it kept with the patch.
    @Test func aMacroIsMappedOntoOneOfTheUnitsParams() async throws {
      let suite = "rack-plugin-tests-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }
      let model = Self.model(memory: memory)
      let id = try #require(model.add("plugin"))
      model.choosePlugin(id, Self.lowpass)
      await model.pluginsReady()
      let unit = try #require(Self.unit(model, id))
      let cutoff = try #require(unit.parameters.values.first { $0.address == 0 })
      cutoff.value = 1000

      model.mapMacro(id, 1, to: cutoff.keyPath)
      let control = PluginControl(macro: 1, key: cutoff.keyPath, name: cutoff.displayName)
      #expect(model.patch.modules[0].plugin?.controls == [control])
      let knob = try #require(model.patch.modules[0].params["macro1"])
      #expect(
        abs(knob - HostedAudioUnit.fraction(of: cutoff)) < 1e-9, "no jump: the knob is where the param is")
      #expect(knob > 0 && knob < 1)
      #expect(unit.mapping(0) == 0)
      #expect(model.macroParameter(id, 1)?.parameter?.key == cutoff.keyPath)
      #expect(model.undoTitle == "Undo Map Macro 1")

      model.undo()
      #expect(model.patch.modules[0].plugin?.controls == [])
      #expect(unit.mapping(0) == nil)
      model.redo()
      #expect(unit.mapping(0) == 0)

      // Kept, and found again by key in a new instance.
      let again = RackSession(plugins: AudioUnitHosting(), memory: memory)
      await again.pluginsReady()
      #expect(again.patch.modules[0].plugin?.controls == [control])
      #expect(Self.unit(again, id)?.mapping(0) == 0)

      model.mapMacro(id, 1, to: nil)
      #expect(unit.mapping(0) == nil)
      #expect(model.undoTitle == "Undo Unmap Macro 1")
    }

    /// Waiting to learn, a macro takes the next param moved in the unit, except one another macro
    /// already turns.
    @Test func aMacroLearnsTheNextParamMoved() async throws {
      let model = Self.model()
      let id = try #require(model.add("plugin"))
      model.choosePlugin(id, Self.lowpass)
      await model.pluginsReady()
      let unit = try #require(Self.unit(model, id))
      let parameters = unit.parameters.values.sorted { $0.address < $1.address }
      let (cutoff, resonance) = (parameters[0], parameters[1])
      model.mapMacro(id, 1, to: cutoff.keyPath)

      model.learnMacro(id, 2)
      #expect(model.learning?.macro == 2)
      cutoff.value = 500
      resonance.value = 6
      for _ in 0..<40 where model.learning != nil { try await Task.sleep(for: .milliseconds(50)) }
      #expect(model.learning == nil)
      #expect(model.macroParameter(id, 2)?.control.key == resonance.keyPath)
      #expect(model.macroParameter(id, 1)?.control.key == cutoff.keyPath, "the first left as it was")
    }

    @Test func aMacroSaysItsValueInTheParamsWords() async throws {
      let model = Self.model()
      let id = try #require(model.add("plugin"))
      model.choosePlugin(id, Self.lowpass)
      await model.pluginsReady()
      let cutoff = try #require(Self.unit(model, id)?.parameters.values.first { $0.address == 0 })
      #expect(
        HostedAudioUnit.display(cutoff, at: 0).hasPrefix("10"), "\(HostedAudioUnit.display(cutoff, at: 0))")
      #expect(HostedAudioUnit.display(cutoff, at: 1).hasPrefix("23760"))
      #expect(HostedAudioUnit.display(cutoff, at: 1).hasSuffix("Hz"))
    }

    @Test func thePickerHasACardForEach() {
      #expect(ModuleFace.shelves.first { $0.name == "Effects" }?.types.contains("plugin") == true)
      #expect(ModuleFace.shelves.first { $0.name == "Sources" }?.types.contains("plugin-instrument") == true)
      // Full width, for four macros beside the unit, and as tall as the jacks need.
      #expect(RackLayout.size(of: "plugin") == RackLayout.Size(span: 2, rows: 3))
      #expect(RackLayout.size(of: "plugin-instrument") == RackLayout.Size(span: 2, rows: 6))
    }

    // MARK: Instruments

    /// An instrument comes played: wired from the rack's MIDI module, or a new one, and to an Out.
    @Test func anInstrumentComesWiredToTheKeys() async throws {
      let model = Self.model()
      let synth = try #require(model.add("plugin-instrument"))
      #expect(model.patch.modules.map(\.type) == ["midi", "plugin-instrument", "out"])
      let keys = model.patch.modules[0].id
      let wired = Set(
        model.patch.cables.map { "\($0.from.module).\($0.from.port)>\($0.to.module).\($0.to.port)" })
      #expect(
        wired == [
          "\(keys).pitch>\(synth).pitch", "\(keys).gate>\(synth).gate", "\(keys).vel>\(synth).velocity",
          "\(synth).out>\(model.patch.modules[2].id).in",
        ])
      #expect(model.undoTitle == "Undo Add Plug-in Instrument", "one step, however much it added")

      // A second shares the keys.
      let another = try #require(model.add("plugin-instrument"))
      #expect(model.patch.modules.filter { $0.type == "midi" }.count == 1)
      #expect(
        model.patch.cables.contains { $0.from.module == keys && $0.to == PortReference(another, "gate") })

      model.choosePlugin(synth, Self.dls)
      await model.pluginsReady()
      guard case .ready = model.plugins[synth] else {
        Issue.record("not ready: \(String(describing: model.plugins[synth]))")
        return
      }
      #expect(model.host.externalModules == [synth])
      #expect(
        PluginFace.detail(nil, nil, instrument: true)
          == "An Audio Unit instrument, played by the rack's notes")
    }

    static let dls = PluginReference(
      format: "audio-unit", id: "aumu dls  appl", name: "DLSMusicDevice", vendor: "Apple")
  }
#endif
