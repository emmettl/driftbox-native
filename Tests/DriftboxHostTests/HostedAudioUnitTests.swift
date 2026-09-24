#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxHost
  import DriftboxRack
  import Testing

  /// An Audio Unit in a `plugin` module, played by the rack's host: Apple's own low-pass, which every
  /// Mac has, so what it does to a signal is known without trusting anything else here.
  struct HostedAudioUnitTests {
    static let lowpass = AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: 0x6c70_6173,  // 'lpas'
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// `source` through a `plugin` module, or straight to the Out when `through` is false.
    static func patch(_ source: PatchModule, through: Bool = true) -> Patch {
      let port = source.type == "noise" ? "white" : "out"
      guard through else {
        return Patch(
          modules: [source, PatchModule(id: "out", type: "out")],
          cables: [PatchCable(from: PortReference(source.id, port), to: PortReference("out", "in"))])
      }
      return Patch(
        modules: [source, PatchModule(id: "fx", type: "plugin"), PatchModule(id: "out", type: "out")],
        cables: [
          PatchCable(from: PortReference(source.id, port), to: PortReference("fx", "in")),
          PatchCable(from: PortReference("fx", "out"), to: PortReference("out", "in")),
        ])
    }

    static let level = PatchModule(id: "dc", type: "offset", params: ["offset": 0.5])

    /// `blocks` blocks of 128 from the host, left then right, in device-sized pieces that do not
    /// line up with the rack's.
    static func render(_ host: RackHost, blocks: Int) -> (left: [Float], right: [Float]) {
      let left = UnsafeMutablePointer<Float>.allocate(capacity: 96)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: 96)
      defer {
        left.deallocate()
        right.deallocate()
      }
      var out: ([Float], [Float]) = ([], [])
      for _ in 0..<(blocks * 128 / 96) {
        host.render(frames: 96, left: left, right: right)
        out.0 += UnsafeBufferPointer(start: left, count: 96)
        out.1 += UnsafeBufferPointer(start: right, count: 96)
      }
      return out
    }

    static func rms(_ samples: some Collection<Float>) -> Double {
      (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
    }

    /// A low-pass lets a steady level through as it is: what reaches the Out through the unit is
    /// what reaches it without, once the filter has settled, on both sides.
    @Test func aSteadyLevelPassesThroughTheUnit() async throws {
      let unit = try await HostedAudioUnit.instantiate(Self.lowpass, sampleRate: 48000)
      let host = RackHost(sampleRate: 48000)
      host.load(Self.patch(Self.level))
      host.setExternal("fx", unit.external)
      let through = Self.render(host, blocks: 60)

      let dry = RackHost(sampleRate: 48000)
      dry.load(Self.patch(Self.level, through: false))
      let expected = Self.render(dry, blocks: 60)
      let settled = expected.left.last!
      #expect(settled > 0.1)
      #expect(abs(through.left.last! - settled) < 1e-3)
      #expect(abs(through.right.last! - expected.right.last!) < 1e-3)
    }

    /// And takes the top off noise: set low, most of it is gone.
    @Test func theUnitIsWhatIsHeard() async throws {
      let unit = try await HostedAudioUnit.instantiate(Self.lowpass, sampleRate: 48000)
      let cutoff = try #require(unit.unit.parameterTree?.parameter(withAddress: 0))
      cutoff.value = 200
      let noise = PatchModule(id: "hiss", type: "noise")
      let host = RackHost(sampleRate: 48000)
      host.load(Self.patch(noise))
      host.setExternal("fx", unit.external)
      let filtered = Self.render(host, blocks: 80).left.suffix(4096)

      let dry = RackHost(sampleRate: 48000)
      dry.load(Self.patch(noise, through: false))
      let raw = Self.render(dry, blocks: 80).left.suffix(4096)
      #expect(Self.rms(raw) > 0.05)
      #expect(Self.rms(filtered) < Self.rms(raw) * 0.3, "\(Self.rms(filtered)) of \(Self.rms(raw))")
      // Filtered, not silenced: the bottom of the noise is still there.
      #expect(Self.rms(filtered) > Self.rms(raw) * 0.02, "\(Self.rms(filtered)) of \(Self.rms(raw))")
    }

    /// The same unit plays on through an edit that rebuilds the graph, and taking it away leaves the
    /// module silent.
    @Test func theUnitOutlivesARebuildAndCanBeTakenAway() async throws {
      let unit = try await HostedAudioUnit.instantiate(Self.lowpass, sampleRate: 48000)
      let host = RackHost(sampleRate: 48000)
      var patch = Self.patch(Self.level)
      host.load(patch)
      host.setExternal("fx", unit.external)
      _ = Self.render(host, blocks: 20)
      patch.modules[0].params["offset"] = 0.25
      host.load(patch)
      let rebuilt = Self.render(host, blocks: 60)
      #expect(rebuilt.left.last! > 0.05, "still through the unit after the rebuild")
      #expect(host.externalModules == ["fx"])

      host.setExternal("fx", nil)
      let gone = Self.render(host, blocks: 60)
      #expect(abs(gone.left.last!) < 1e-4, "silent without it")
      #expect(host.externalModules.isEmpty)
    }

    /// What the patch keeps is enough to make the same unit again, set as it was.
    @Test func theUnitComesBackFromThePatch() async throws {
      let unit = try await HostedAudioUnit.instantiate(Self.lowpass, sampleRate: 48000)
      try #require(unit.unit.parameterTree?.parameter(withAddress: 0)).value = 321
      let reference = unit.reference
      #expect(reference.format == "audio-unit")
      #expect(reference.id == "aufx lpas appl")
      #expect(reference.name == "AULowpass")
      #expect(reference.vendor == "Apple")
      let state = try #require(reference.state)

      let component = try #require(HostedAudioUnit.component(reference.id))
      let again = try await HostedAudioUnit.instantiate(component, sampleRate: 48000, state: state)
      let cutoff = try #require(again.unit.parameterTree?.parameter(withAddress: 0))
      #expect(cutoff.value == 321)
      #expect(again.latency >= 0)
    }

    @Test func aUnitThisMacDoesNotHaveIsMissing() async {
      let nothing = try! #require(HostedAudioUnit.component("aufx zzzz zzzz"))
      await #expect(throws: HostedAudioUnit.Failure.missing) {
        _ = try await HostedAudioUnit.instantiate(nothing, sampleRate: 48000)
      }
    }

    @Test func identifiersAreTheFourCharacterCodes() {
      #expect(HostedAudioUnit.identifier(Self.lowpass) == "aufx lpas appl")
      let back = HostedAudioUnit.component("aufx lpas appl")
      #expect(back?.componentType == kAudioUnitType_Effect)
      #expect(back?.componentSubType == 0x6c70_6173)
      #expect(back?.componentManufacturer == kAudioUnitManufacturer_Apple)
      #expect(HostedAudioUnit.component("aufx lpas") == nil)
      #expect(HostedAudioUnit.component("aufx lpass appl") == nil)
    }
  }
#endif
