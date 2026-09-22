#if canImport(AVFoundation)
  import AVFoundation
  import ConformanceSupport
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxHost
  import Foundation
  import Testing

  struct AudioUnitTests {
    /// The audio unit, rendered by hand through its render block, gives the engine's samples.
    @Test func theAudioUnitRendersTheEngine() throws {
      let song = try #require(SongCodec.decode(try Fixtures.text("documents/garage.song.json")))
      let unit = try DriftboxAudioUnit(componentDescription: DriftboxAudioUnit.componentDescription)
      unit.load(song)
      unit.send(.play)
      try unit.allocateRenderResources()
      let render = unit.renderBlock

      let frames = 24000
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      var left: [Float] = []
      var right: [Float] = []
      var done = 0
      var timestamp = AudioTimeStamp()
      timestamp.mFlags = .sampleTimeValid
      while done < frames {
        let count = min(1024, frames - done)
        buffer.frameLength = AVAudioFrameCount(count)
        timestamp.mSampleTime = Double(done)
        var flags = AudioUnitRenderActionFlags()
        let status = render(
          &flags, &timestamp, AVAudioFrameCount(count), 0, buffer.mutableAudioBufferList, nil)
        #expect(status == noErr)
        left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)
        right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)
        done += count
      }

      var engine = SongEngine(sampleRate: 48000)
      let compiled = UnsafeMutablePointer<CompiledSong>.allocate(capacity: 1)
      compiled.initialize(to: CompiledSong(song, preparer: engine.voices.preparer))
      engine.load(compiled)
      engine.play()
      var expected = [Float](repeating: 0, count: frames)
      var expectedRight = [Float](repeating: 0, count: frames)
      expected.withUnsafeMutableBufferPointer { l in
        expectedRight.withUnsafeMutableBufferPointer { r in
          engine.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!)
        }
      }
      engine.load(nil)
      compiled.deinitialize(count: 1)
      compiled.deallocate()

      #expect(left == expected && right == expectedRight)
      #expect(left.contains { $0 != 0 })
      unit.deallocateRenderResources()
    }
  }
#endif
