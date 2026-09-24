#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxHost
  import DriftboxHostMac
  import DriftboxRack
  import Foundation
  import Synchronization
  import Testing

  /// The rack as an Audio Unit: what it renders, the rate it will play at, what it saves and
  /// restores, and that it carries on through its engine stopping and starting.
  struct RackAudioUnitTests {
    /// A free-running VCO into an Out.
    static let patch = Patch(
      modules: [PatchModule(id: "osc", type: "vco"), PatchModule(id: "out", type: "out")],
      cables: [PatchCable(from: PortReference("osc", "out"), to: PortReference("out", "in"))])

    static func unit(_ host: RackHost?) throws -> RackAudioUnit {
      let unit = try RackAudioUnit(componentDescription: RackAudioUnit.componentDescription)
      unit.host = host
      return unit
    }

    /// Through the render block, in the uneven lengths a device asks for, exactly what the host
    /// renders when asked directly.
    @Test func theUnitRendersItsHost() throws {
      let heard = RackHost(sampleRate: 48000)
      let direct = RackHost(sampleRate: 48000)
      heard.load(Self.patch)
      direct.load(Self.patch)
      let unit = try Self.unit(heard)
      try unit.allocateRenderResources()
      defer { unit.deallocateRenderResources() }
      let render = unit.renderBlock
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
      let left = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
      defer {
        left.deallocate()
        right.deallocate()
      }
      var timestamp = AudioTimeStamp()
      timestamp.mFlags = .sampleTimeValid
      var loud = false
      for count in [512, 441, 1024, 7, 300, 128] {
        buffer.frameLength = AVAudioFrameCount(count)
        var flags = AudioUnitRenderActionFlags()
        #expect(
          render(&flags, &timestamp, AVAudioFrameCount(count), 0, buffer.mutableAudioBufferList, nil) == noErr
        )
        direct.render(frames: count, left: left, right: right)
        let l = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)
        let r = UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)
        #expect(Array(l) == Array(UnsafeBufferPointer(start: left, count: count)))
        #expect(Array(r) == Array(UnsafeBufferPointer(start: right, count: count)))
        loud = loud || l.contains { $0 != 0 }
        timestamp.mSampleTime += Double(count)
      }
      #expect(loud)
    }

    @Test func withNoHostItIsSilent() throws {
      let unit = try Self.unit(nil)
      try unit.allocateRenderResources()
      defer { unit.deallocateRenderResources() }
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
      buffer.frameLength = 256
      for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 1, count: 256) }
      var timestamp = AudioTimeStamp()
      var flags = AudioUnitRenderActionFlags()
      #expect(unit.renderBlock(&flags, &timestamp, 256, 0, buffer.mutableAudioBufferList, nil) == noErr)
      for channel in 0..<2 {
        #expect(
          UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: 256).allSatisfy { $0 == 0 })
      }
    }

    /// It plays at its host's rate and says no to any other, rather than playing at the wrong pitch.
    @Test func itPlaysAtItsHostsRateAndNoOther() throws {
      let unit = try Self.unit(RackHost(sampleRate: 44100))
      let bus = unit.outputBusses[0]
      #expect(bus.format.sampleRate == 44100)
      let faster = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
      #expect(!unit.shouldChange(to: faster, for: bus))
      #expect(throws: (any Error).self) { try bus.setFormat(faster) }
      let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
      #expect(!unit.shouldChange(to: mono, for: bus))
      try unit.allocateRenderResources()
      unit.deallocateRenderResources()
    }

    /// What a plug-in host saves is the patch as a document, with its name; what it restores is
    /// handed to the rack's owner to open.
    @Test func itsStateIsThePatch() throws {
      let unit = try Self.unit(RackHost(sampleRate: 48000))
      #expect(unit.fullState?["patch"] == nil)
      unit.saved.withLock { $0 = (#"{"v":2,"patch":{"modules":[],"cables":[]}}"#, "Empty") }
      let state = try #require(unit.fullState)
      #expect(state["patch"] as? String == #"{"v":2,"patch":{"modules":[],"cables":[]}}"#)
      #expect(state["name"] as? String == "Empty")

      let restored = Mutex<[(String, String?)]>([])
      unit.restore = { document, name in restored.withLock { $0.append((document, name)) } }
      unit.fullState = state
      unit.fullState = ["patch": "a document"]
      unit.fullState = ["something": "else"]
      let seen = restored.withLock { $0 }
      #expect(seen.map(\.0) == [#"{"v":2,"patch":{"modules":[],"cables":[]}}"#, "a document"])
      #expect(seen.map(\.1) == ["Empty", nil])
    }

    /// In an engine that stops and starts — as `AVAudioEngine` does on its own when the output
    /// device changes — the rack carries on, its host kept and its clock running on.
    @Test func itCarriesOnThroughAStopAndAStart() async throws {
      AUAudioUnit.registerSubclass(
        RackAudioUnit.self, as: RackAudioUnit.componentDescription, name: "Driftbox Rack", version: 1)
      let node = try await AVAudioUnit.instantiate(with: RackAudioUnit.componentDescription, options: [])
      let unit = try #require(node.auAudioUnit as? RackAudioUnit)
      let host = RackHost(sampleRate: 48000)
      host.load(Self.patch)
      unit.host = host
      let engine = AVAudioEngine()
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))
      try engine.start()
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
      for _ in 0..<10 { _ = try engine.renderOffline(512, to: buffer) }
      let before = host.frame.load(ordering: .relaxed)
      #expect(before >= 10 * 512)

      engine.stop()
      try engine.start()
      for _ in 0..<4 { _ = try engine.renderOffline(512, to: buffer) }
      #expect(unit.host === host)
      #expect(host.frame.load(ordering: .relaxed) == before + 4 * 512)
      let heard = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 512)
      #expect(heard.contains { $0 != 0 })
    }
  }
#endif
