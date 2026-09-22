#if canImport(AVFoundation)
  import AVFoundation
  import ConformanceSupport
  import DriftboxDocument
  import DriftboxHost
  import Foundation
  import Testing

  /// What happens to the song when the engine around the audio unit stops and starts — which
  /// `AVAudioEngine` does on its own whenever the output device changes. Run in manual rendering
  /// mode, so the whole lifecycle is exercised with no audio device at all.
  struct LifecycleTests {
    struct Rig {
      let engine: AVAudioEngine
      let node: AVAudioUnit
      let unit: DriftboxAudioUnit
      let buffer: AVAudioPCMBuffer

      func render(blocks: Int) throws {
        for _ in 0..<blocks { _ = try engine.renderOffline(512, to: buffer) }
      }
    }

    func rig() async throws -> Rig {
      AUAudioUnit.registerSubclass(
        DriftboxAudioUnit.self, as: DriftboxAudioUnit.componentDescription, name: "Driftbox", version: 1)
      let node = try await AVAudioUnit.instantiate(with: DriftboxAudioUnit.componentDescription, options: [])
      let unit = try #require(node.auAudioUnit as? DriftboxAudioUnit)
      let engine = AVAudioEngine()
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))
      try engine.start()
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
      let song = try #require(SongCodec.decode(try Fixtures.text("documents/acid.song.json")))
      unit.load(song)
      unit.send(.play)
      return Rig(engine: engine, node: node, unit: unit, buffer: buffer)
    }

    /// The song carries on from where it stopped. It used to come back from the next start with
    /// no song loaded at all, because the unit threw its engine away when it was deallocated.
    @Test func aStopAndAStartCarryOnFromTheSamePlace() async throws {
      let rig = try await rig()
      try rig.render(blocks: 50)
      let before = try #require(rig.unit.host).songFrame.load(ordering: .relaxed)
      #expect(before == 50 * 512)

      rig.engine.stop()
      try rig.engine.start()
      try rig.render(blocks: 5)
      let host = try #require(rig.unit.host)
      let after = host.songFrame.load(ordering: .relaxed)
      let playing = host.playing.load(ordering: .relaxed)
      #expect(after == before + 5 * 512)
      #expect(playing)
    }

    /// A host may give the unit a different sample rate between a stop and a start. The engine
    /// is made again at the new rate, with the same song, at the same *time* in it.
    @Test func aNewSampleRateKeepsTheSong() async throws {
      let rig = try await rig()
      try rig.render(blocks: 60)
      let seconds = Double(try #require(rig.unit.host).songFrame.load(ordering: .relaxed)) / 48000

      rig.engine.stop()
      let slower = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
      try rig.unit.outputBusses[0].setFormat(slower)
      rig.engine.disconnectNodeOutput(rig.node)
      rig.engine.connect(rig.node, to: rig.engine.mainMixerNode, format: slower)
      try rig.engine.start()
      try rig.render(blocks: 1)

      let host = try #require(rig.unit.host)
      let playing = host.playing.load(ordering: .relaxed)
      #expect(host.sampleRate == 44100)
      #expect(playing)
      let now = Double(host.songFrame.load(ordering: .relaxed)) / 44100
      // Where it was, plus one block of the new rate's worth of time, give or take the frames
      // the converter is holding.
      #expect(abs(now - seconds) < 0.05, "\(seconds) then \(now)")
    }
  }
#endif
