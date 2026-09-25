#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxDocument
  import DriftboxHostMac
  import DriftboxRack
  import DriftboxRackSession
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import DriftboxExtensions
  @testable import DriftboxHost

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
    static func render(_ unit: InstrumentAudioUnit, frames: Int) -> [Float] {
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

    /// The rack keeps the app's time: its tempo, and running while the app's transport moves, its
    /// clock at the app's beat.
    @Test func theRackKeepsTheAppsTime() throws {
      let (unit, plugin) = try Self.unit()
      let clock = AppClock(tempo: 97, beat: 8)
      clock.attach(to: unit)
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(!session.running)
      _ = Self.render(unit, frames: 512)
      plugin.tick()
      #expect(session.tempo == 97)
      #expect(!session.running)

      clock.moving = true
      _ = Self.render(unit, frames: 512)
      plugin.tick()
      #expect(session.running)
      let beat = session.host.current.pointee?.pointee.beatPosition ?? 0
      #expect(beat > 8 && beat < 8.1, "at the app's beat, not rewound to the top")

      // A change the rack follows, not a state it is held to: stopped from the face while the app
      // plays, it stays stopped.
      session.toggleRunning()
      for _ in 0..<4 {
        _ = Self.render(unit, frames: 512)
        plugin.tick()
      }
      #expect(!session.running)
    }

    /// The session is ticked as the face draws, so its meters move inside the app as in the Mac app.
    @Test func theMetersAreRead() throws {
      let (unit, plugin) = try Self.unit()
      try unit.allocateRenderResources()
      let session = try #require(plugin.session)
      #expect(session.readings.isEmpty)
      _ = Self.render(unit, frames: 4410)
      for _ in 0..<Plugins.sessionEvery { plugin.tick() }
      #expect(!session.readings.isEmpty)
    }

    /// How many colours `view` draws in, sampled across it: a measure of how much it draws.
    static func colours(_ view: some View) throws -> Int {
      let hosting = NSHostingView(rootView: view)
      hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 760)
      hosting.layoutSubtreeIfNeeded()
      let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      var colours = Set<Int>()
      for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
          guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          colours.insert(
            Int(c.redComponent * 255) << 16 | Int(c.greenComponent * 255) << 8 | Int(c.blueComponent * 255))
        }
      }
      return colours.count
    }

    /// The face is the rack's own, on the session the unit plays, made again with it; and it draws.
    @Test func theFaceIsTheRacksOwn() throws {
      let (unit, plugin) = try Self.unit()
      #expect(plugin.face == nil)
      let waiting = try Self.colours(RackPluginView(plugin: plugin))
      try unit.allocateRenderResources()
      let face = try #require(plugin.face)
      #expect(face.session === plugin.session)

      #expect(try Self.colours(RackPluginView(plugin: plugin)) > 4 * waiting)

      unit.deallocateRenderResources()
      try unit.outputBusses[0].setFormat(
        try #require(AVAudioFormat(standardFormatWithSampleRate: 96000, channels: 2)))
      try unit.allocateRenderResources()
      #expect(plugin.face !== face)
      #expect(plugin.face?.session === plugin.session)
    }
  }
#endif
