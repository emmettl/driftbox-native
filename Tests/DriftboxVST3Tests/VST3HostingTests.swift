#if os(Windows)
  import DriftboxHostVST3
  import DriftboxRack
  @testable import DriftboxRackSession
  import Foundation
  import Testing

  /// The rack's VST 3 plug-ins: found where they are installed, and made, played, turned and kept
  /// by a real rack, on the test plug-in.
  @MainActor
  struct VST3HostingTests {
    /// The folder the test plug-in is installed in.
    static var folder: URL { URL(fileURLWithPath: VST3BridgeTests.bundle).deletingLastPathComponent() }

    /// A module's plug-ins are found in the folders given: an effect and an instrument, by class ID
    /// in any case, and nothing for a class that is not there.
    @Test func theInstalledAreFound() throws {
      let catalogue = VST3Catalogue.scan([Self.folder, URL(fileURLWithPath: "C:/nowhere")])
      #expect(catalogue.entries.map(\.reference.name) == ["Driftbox Test Gain", "Driftbox Test Synth"])
      #expect(catalogue.entries.map(\.isInstrument) == [false, true])
      let gain = try #require(catalogue.entry(VST3BridgeTests.gainID.lowercased()))
      #expect(gain.reference.format == "vst3" && gain.reference.vendor == "Driftbox")
      #expect(gain.path == VST3BridgeTests.bundle)
      #expect(catalogue.entry("0123456789ABCDEF0123456789ABCDEF") == nil)
    }

    /// A module that says what it holds in its `moduleinfo.json` is read, not loaded — this one
    /// has nothing to load — in a vendor's folder of its own; its controller class is no plug-in,
    /// and a class with no vendor of its own has the module's.
    @Test func aModuleThatDescribesItselfIsRead() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "driftbox-vst3-\(UUID().uuidString)")
      let resources = root.appendingPathComponent("Maker/Echo.vst3/Contents/Resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let info = """
        {
          "Name": "Echo", "Version": "1.0",
          "Factory Info": { "Vendor": "Maker", "URL": "", "E-Mail": "" },
          "Classes": [
            { "CID": "0123456789abcdef0123456789abcdef", "Category": "Audio Module Class", "Name": "Echo",
              "Vendor": "", "Sub Categories": ["Fx", "Delay"] },
            { "CID": "FEDCBA9876543210FEDCBA9876543210", "Category": "Component Controller Class",
              "Name": "Echo Controller" }
          ]
        }
        """
      try Data(info.utf8).write(to: resources.appendingPathComponent("moduleinfo.json"))
      try Data().write(to: root.appendingPathComponent("readme.txt"))

      let catalogue = VST3Catalogue.scan([root])
      #expect(catalogue.entries.count == 1)
      let echo = try #require(catalogue.entries.first)
      #expect(echo.reference.id == "0123456789ABCDEF0123456789ABCDEF")
      #expect(
        echo.reference.vendor == "Maker" && echo.subCategories == ["Fx", "Delay"] && !echo.isInstrument)
      #expect(echo.path.hasSuffix("Echo.vst3"))
    }

    /// A rack with an effect module: a VCO through the test gain into the Out.
    static func effectRack(_ reference: PluginReference) -> RackSession {
      var effect = PatchModule(id: "fx", type: "plugin")
      effect.plugin = reference
      let rack = RackSession(plugins: VST3Hosting(folders: [folder]))
      rack.open(
        Patch(
          modules: [PatchModule(id: "osc", type: "vco"), effect, PatchModule(id: "out", type: "out")],
          cables: [
            PatchCable(from: PortReference("osc", "out"), to: PortReference("fx", "in")),
            PatchCable(from: PortReference("fx", "out"), to: PortReference("out", "in")),
          ]),
        name: "FX")
      return rack
    }

    static func reference(_ id: String, format: String = "vst3") -> PluginReference {
      PluginReference(format: format, id: id, name: "Test", vendor: "Driftbox")
    }

    /// How loud the rack is over a tenth of a second, and a tenth before it to let it settle.
    static func loudness(_ rack: RackSession) -> Float {
      let frames = 4800
      let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      defer {
        left.deallocate()
        right.deallocate()
      }
      rack.host.render(frames: frames, left: left, right: right)
      rack.host.render(frames: frames, left: left, right: right)
      return (0..<frames).reduce(0) { max($0, abs(left[$1])) }
    }

    /// An effect is made from the patch's reference and plays in the rack, how late it is said; a
    /// macro maps onto its gain where the gain is and turns it, down to silence; and its settings
    /// are kept in the patch, and come back with it.
    @Test func anEffectPlaysInTheRack() async throws {
      let rack = Self.effectRack(Self.reference(VST3BridgeTests.gainID))
      rack.listen()
      await rack.pluginsReady()
      #expect(rack.plugins["fx"] == .ready(latency: 32.0 / 48000))
      let half = Self.loudness(rack)
      #expect(half > 0.01)

      rack.mapMacro("fx", 1, to: "0")
      #expect(rack.patch.modules[1].plugin?.controls == [PluginControl(macro: 1, key: "0", name: "Gain")])
      #expect(rack.patch.modules[1].params["macro1"] == 0.5)
      #expect(abs(Self.loudness(rack) - half) < 0.01, "nothing jumps")
      rack.turn("fx", "macro1", to: 1)
      #expect(abs(Self.loudness(rack) - 2 * half) < 0.02)
      rack.turn("fx", "macro1", to: 0)
      #expect(Self.loudness(rack) == 0)
      rack.endTurn()
      // Said to have changed, the unit's state is saved once things are still for a moment.
      // Waited for, not timed: with the whole suite running, a moment can be a long one.
      rack.unitChanged("fx")
      for _ in 0..<100 where rack.patch.modules[1].plugin?.state == nil {
        try await Task.sleep(for: .milliseconds(50))
      }
      let saved = try #require(rack.patch.modules[1].plugin)
      #expect(saved.state != nil)
      let again = Self.effectRack(saved)
      again.listen()
      await again.pluginsReady()
      #expect(again.units["fx"]?.parameters["0"]?.fraction == 0, "its gain as it was left")
    }

    /// A plug-in that is not installed, or an Audio Unit from a Mac, is missing, and silent.
    @Test func whatIsNotHereIsMissing() async {
      for reference in [
        Self.reference("0123456789ABCDEF0123456789ABCDEF"),
        Self.reference("aufx dely appl", format: "audio-unit"),
      ] {
        let rack = Self.effectRack(reference)
        await rack.pluginsReady()
        #expect(rack.plugins["fx"] == .missing)
      }
    }

    /// What there is to choose: the effect for a `plugin` module, the instrument for a
    /// `plugin-instrument` one.
    @Test func theInstalledAreOffered() async {
      let rack = RackSession(plugins: VST3Hosting(folders: [Self.folder]))
      rack.findPlugins()
      await rack.pluginsFound()
      guard case .found(let choices) = rack.pluginChoices else {
        Issue.record("not found")
        return
      }
      #expect(choices.map(\.reference.name) == ["Driftbox Test Gain", "Driftbox Test Synth"])
      #expect(choices.map(\.moduleType) == ["plugin", "plugin-instrument"])
    }

    /// An instrument module plays the test synth from the rack's keys, at the level a pitch bend at
    /// rest puts it.
    @Test func anInstrumentPlaysTheKeys() async {
      var synth = PatchModule(id: "synth", type: "plugin-instrument")
      synth.plugin = Self.reference(VST3BridgeTests.synthID)
      let rack = RackSession(plugins: VST3Hosting(folders: [Self.folder]))
      rack.open(
        Patch(
          modules: [PatchModule(id: "keys", type: "midi"), synth, PatchModule(id: "out", type: "out")],
          cables: [
            PatchCable(from: PortReference("keys", "pitch"), to: PortReference("synth", "pitch")),
            PatchCable(from: PortReference("keys", "gate"), to: PortReference("synth", "gate")),
            PatchCable(from: PortReference("synth", "out"), to: PortReference("out", "in")),
          ]),
        name: "Keys")
      rack.listen()
      await rack.pluginsReady()
      #expect(Self.loudness(rack) == 0)
      rack.noteDown(57)
      #expect(Self.loudness(rack) > 0.01)
      rack.noteUp(57)
      #expect(Self.loudness(rack) == 0)
    }
  }
#endif
