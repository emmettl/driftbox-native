#if canImport(AVFoundation)
  import AVFoundation
  import DriftboxRackSession

  /// Audio files as the Mac reads them: whatever Core Audio can open — WAV, AIFF, MP3, AAC, FLAC,
  /// ALAC — converted to the rack's rate, every channel. The rack's own WAV reader is what a platform
  /// without it falls back on; this is what a file dropped on a sampler is read with here.
  struct AudioFileDecoder: SampleDecoding {
    var readable: String { "a WAV, AIFF, MP3 or FLAC" }

    func decode(_ url: URL, sampleRate: Double) throws -> [[Float]] {
      let file = try AVAudioFile(forReading: url)
      let channels = max(1, Int(file.processingFormat.channelCount))
      guard
        let target = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels),
          interleaved: false),
        let source = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length)))
      else { throw CocoaError(.fileReadCorruptFile) }
      try file.read(into: source)
      guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw CocoaError(.fileReadUnknown)
      }
      let capacity =
        AVAudioFrameCount(Double(source.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
      guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      var supplied = false
      var failure: NSError?
      let status = converter.convert(to: output, error: &failure) { _, state in
        if supplied {
          state.pointee = .endOfStream
          return nil
        }
        supplied = true
        state.pointee = .haveData
        return source
      }
      if status == .error { throw failure ?? CocoaError(.fileReadUnknown) }
      guard let data = output.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
      return (0..<channels).map {
        Array(UnsafeBufferPointer(start: data[$0], count: Int(output.frameLength)))
      }
    }
  }
#endif
