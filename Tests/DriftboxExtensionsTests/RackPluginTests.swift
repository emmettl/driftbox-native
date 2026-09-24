#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHostMac
  import DriftboxRack
  import DriftboxRackSession
  import Foundation
  import Testing

  @testable import DriftboxExtensions

  /// The rack's Audio Unit as another app sees it, with its owner behind it: made at the app's rate,
  /// its presets the factory patches and its state the patch, played by the app's MIDI, and keeping
  /// the app's time. Made in-process here, as the extension makes it out of process.
  @MainActor
  struct RackPluginTests {
    static func unit(rate: Double = 44100) throws -> (RackAudioUnit, RackPlugin) {
      let unit = try RackAudioUnit(componentDescription: RackAudioUnit.componentDescription)
      RackPlugin.attach(to: unit)
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
      try unit.outputBusses[0].setFormat(format)
      return (unit, try #require(unit.owner as? RackPlugin))
    }

    /// `frames` rendered as the app would render them.
    static func render(_ unit: RackAudioUnit, frames: Int) -> [Float] {
      let list = AudioBufferList.allocate(maximumBuffers: 2)
      defer { free(list.unsafeMutablePointer) }
      let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
      defer {
        left.deallocate()
        right.deallocate()
      }
      var out: [Float] = []
      var done = 0
      while done < frames {
        let count = min(512, frames - done)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: left)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: right)
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = Double(done)
        time.mFlags = .sampleTimeValid
        _ = unit.renderBlock(&flags, &time, AUAudioFrameCount(count), 0, list.unsafeMutablePointer, nil)
        out += UnsafeBufferPointer(start: left, count: count)
        done += count
      }
      return out
    }

    @Test func aRackIsMadeAtTheAppsRate() throws {
      let (unit, plugin) = try Self.unit(rate: 44100)
      #expect(plugin.session == nil, "nothing until the app readies the unit")
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(session.host.sampleRate == 44100)
      #expect(unit.host === session.host)
      #expect(session.name == PatchEntry.all.first { $0.id == RackSession.firstPatch }?.name)

      // Another rate makes the rack again, keeping the patch it had.
      unit.currentPreset = unit.factoryPresets?[2]
      let chosen = session.patch
      unit.deallocateRenderResources()
      try unit.outputBusses[0].setFormat(
        try #require(AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 2)))
      try unit.allocateRenderResources()
      let again = try #require(plugin.session)
      #expect(again !== session)
      #expect(again.host.sampleRate == 96000)
      #expect(again.patch == chosen)
    }

    /// The factory patches are the presets; the state is the patch, and a state restored before the
    /// rack exists is opened when it does.
    @Test func thePresetsAreTheFactoryPatchesAndTheStateIsThePatch() throws {
      let (unit, plugin) = try Self.unit()
      #expect(unit.factoryPresets?.map(\.name) == PatchEntry.all.map(\.name))
      try unit.allocateRenderResources()
      unit.currentPreset = unit.factoryPresets?[3]
      #expect(plugin.session?.name == PatchEntry.all[3].name)
      let state = try #require(unit.fullState)

      let (other, otherPlugin) = try Self.unit()
      other.fullState = state
      try other.allocateRenderResources()
      #expect(otherPlugin.session?.patch == plugin.session?.patch)
      #expect(otherPlugin.session?.name == PatchEntry.all[3].name)
    }

    /// A note from the app plays the rack through its MIDI module.
    @Test func theAppsMIDIPlaysTheRack() throws {
      let (unit, plugin) = try Self.unit()
      let patch = Patch(
        modules: [
          PatchModule(id: "keys", type: "midi"), PatchModule(id: "osc", type: "vco"),
          PatchModule(id: "amp", type: "vca", params: ["gain": 0]), PatchModule(id: "out", type: "out"),
        ],
        cables: [
          PatchCable(from: PortReference("keys", "pitch"), to: PortReference("osc", "pitch")),
          PatchCable(from: PortReference("osc", "out"), to: PortReference("amp", "in")),
          PatchCable(from: PortReference("keys", "gate"), to: PortReference("amp", "cv")),
          PatchCable(from: PortReference("amp", "out"), to: PortReference("out", "in")),
        ])
      unit.fullState = ["patch": PatchCodec.encode(patch), "name": "Keys"]
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(Self.render(unit, frames: 4410).allSatisfy { abs($0) < 1e-4 }, "silent until a key goes down")

      // As an app sends MIDI: scheduled on the unit, which hands it to the render block as an event.
      let schedule = try #require(unit.scheduleMIDIEventBlock)
      let note: [UInt8] = [0x90, 60, 100]
      schedule(AUEventSampleTimeImmediate, 0, 3, note)
      _ = Self.render(unit, frames: 512)
      plugin.tick()
      #expect(session.sounding == [60])
      let held = Self.render(unit, frames: 4410)
      #expect(held.contains { abs($0) > 0.05 }, "heard once the key is down")
    }

    /// The rack keeps the app's time: its tempo, and running while the app's transport moves.
    @Test func theRackKeepsTheAppsTime() throws {
      let (unit, plugin) = try Self.unit()
      unit.musicalContextBlock = { tempo, _, _, _, _, _ in
        tempo?.pointee = 97
        return true
      }
      unit.transportStateBlock = { flags, _, _, _ in
        flags?.pointee = .moving
        return true
      }
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(!session.running)
      _ = Self.render(unit, frames: 512)
      plugin.tick()
      #expect(session.tempo == 97)
      #expect(session.running)
    }
  }
#endif
