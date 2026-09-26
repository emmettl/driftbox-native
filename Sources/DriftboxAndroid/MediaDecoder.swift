#if os(Android)
  import Android
  import CMedia
  import DriftboxRackSession
  import FoundationEssentials

  /// Audio files as Android reads them, as `AudioFileDecoder` is the Mac's: WAV in Swift, exactly,
  /// as every platform reads it, and anything else the phone's own media codecs can open — MP3,
  /// AAC, FLAC, Ogg Vorbis, Opus — taken to the rack's rate, every channel.
  struct MediaDecoder: SampleDecoding {
    var readable: String { "a WAV, MP3, AAC or FLAC" }

    func decode(_ url: URL, sampleRate: Double) throws -> [[Float]] {
      do {
        return try WAVDecoder().decode(url, sampleRate: sampleRate)
      } catch WAVDecodingError.notWAV {
      } catch WAVDecodingError.unsupported(_, _) {
      }
      let (rate, channels) = try Self.read(url.path)
      guard rate != sampleRate else { return channels }
      return channels.map { WAVDecoder.resample($0, from: rate, to: sampleRate) }
    }

    /// The file's first audio track, decoded whole: its rate, and its channels at that rate.
    static func read(_ path: String) throws -> (rate: Double, channels: [[Float]]) {
      let fd = open(path, O_RDONLY)
      guard fd >= 0 else { throw MediaDecodingError.unreadable(path) }
      defer { close(fd) }
      var size = stat()
      guard fstat(fd, &size) == 0, let extractor = AMediaExtractor_new() else {
        throw MediaDecodingError.unreadable(path)
      }
      defer { AMediaExtractor_delete(extractor) }
      guard AMediaExtractor_setDataSourceFd(extractor, fd, 0, off64_t(size.st_size)) == AMEDIA_OK else {
        throw MediaDecodingError.notAudio
      }
      guard let (index, format, mime) = audioTrack(extractor) else { throw MediaDecodingError.notAudio }
      defer { AMediaFormat_delete(format) }
      AMediaExtractor_selectTrack(extractor, index)
      guard let codec = AMediaCodec_createDecoderByType(mime) else {
        throw MediaDecodingError.noDecoder(mime)
      }
      defer { AMediaCodec_delete(codec) }
      guard AMediaCodec_configure(codec, format, nil, nil, 0) == AMEDIA_OK,
        AMediaCodec_start(codec) == AMEDIA_OK
      else { throw MediaDecodingError.noDecoder(mime) }
      defer { AMediaCodec_stop(codec) }

      // What comes out, until the decoder says otherwise: the track's rate and channels, as 16-bit
      // integers, which is what a decoder gives unless asked for more.
      var pcm = PCM(format)
      var interleaved: [Float] = []
      var fed = false
      var idle = 0
      while true {
        if !fed {
          let slot = AMediaCodec_dequeueInputBuffer(codec, 10_000)
          if slot >= 0 {
            var capacity = 0
            let buffer = AMediaCodec_getInputBuffer(codec, Int(slot), &capacity)
            let read = buffer.map { AMediaExtractor_readSampleData(extractor, $0, capacity) } ?? -1
            if read < 0 {
              AMediaCodec_queueInputBuffer(
                codec, Int(slot), 0, 0, 0, UInt32(AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM))
              fed = true
            } else {
              let time = UInt64(max(0, AMediaExtractor_getSampleTime(extractor)))
              AMediaCodec_queueInputBuffer(codec, Int(slot), 0, read, time, 0)
              AMediaExtractor_advance(extractor)
            }
          }
        }
        var info = AMediaCodecBufferInfo()
        let slot = AMediaCodec_dequeueOutputBuffer(codec, &info, 10_000)
        if slot >= 0 {
          idle = 0
          var capacity = 0
          if info.size > 0, let buffer = AMediaCodec_getOutputBuffer(codec, Int(slot), &capacity) {
            pcm.append(UnsafeRawPointer(buffer + Int(info.offset)), bytes: Int(info.size), to: &interleaved)
          }
          AMediaCodec_releaseOutputBuffer(codec, Int(slot), false)
          if info.flags & UInt32(AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0 { break }
        } else if slot == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED {
          if let changed = AMediaCodec_getOutputFormat(codec) {
            pcm = PCM(changed, else: pcm)
            AMediaFormat_delete(changed)
          }
        } else if fed {
          // A decoder that has had everything and says nothing for two seconds has finished
          // without saying so; what it gave is kept.
          idle += 1
          if idle > 200 { break }
        }
      }
      guard pcm.channels > 0, pcm.rate > 0 else { throw MediaDecodingError.notAudio }
      guard !interleaved.isEmpty else { throw MediaDecodingError.empty }
      let frames = interleaved.count / pcm.channels
      let channels = (0..<pcm.channels).map { channel in
        (0..<frames).map { interleaved[$0 * pcm.channels + channel] }
      }
      return (pcm.rate, channels)
    }

    /// The first track whose type is audio: its index, its format and its type.
    private static func audioTrack(_ extractor: OpaquePointer) -> (Int, OpaquePointer, String)? {
      for index in 0..<AMediaExtractor_getTrackCount(extractor) {
        guard let format = AMediaExtractor_getTrackFormat(extractor, index) else { continue }
        var mime: UnsafePointer<CChar>?
        if AMediaFormat_getString(format, MediaKey.mime, &mime), let mime {
          let type = String(cString: mime)
          if type.hasPrefix("audio/") { return (index, format, type) }
        }
        AMediaFormat_delete(format)
      }
      return nil
    }

    /// How a decoder's output is laid out: frames of `channels` samples, each in `encoding`.
    private struct PCM {
      var rate: Double
      var channels: Int
      /// Android's `AudioFormat` encodings: 16-bit integers unless it says otherwise.
      var encoding: Int32

      init(_ format: OpaquePointer, else fallback: PCM? = nil) {
        var value: Int32 = 0
        rate =
          AMediaFormat_getInt32(format, MediaKey.sampleRate, &value)
          ? Double(value) : fallback?.rate ?? 0
        channels =
          AMediaFormat_getInt32(format, MediaKey.channelCount, &value)
          ? Int(value) : fallback?.channels ?? 0
        encoding =
          AMediaFormat_getInt32(format, MediaKey.pcmEncoding, &value)
          ? value : fallback?.encoding ?? Self.pcm16
      }

      static let pcm16: Int32 = 2
      static let pcm8: Int32 = 3
      static let float: Int32 = 4
      static let pcm24: Int32 = 21
      static let pcm32: Int32 = 22

      /// `bytes` of output, each sample from -1 to 1, onto the end of `out`.
      func append(_ start: UnsafeRawPointer, bytes: Int, to out: inout [Float]) {
        let raw = UnsafeRawBufferPointer(start: start, count: bytes)
        switch encoding {
        case Self.float:
          for at in stride(from: 0, to: bytes - 3, by: 4) {
            out.append(raw.loadUnaligned(fromByteOffset: at, as: Float.self))
          }
        case Self.pcm8:
          for byte in raw { out.append((Float(byte) - 128) / 128) }
        case Self.pcm24:
          for at in stride(from: 0, to: bytes - 2, by: 3) {
            let word = UInt32(raw[at]) << 8 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 24
            out.append(Float(Int32(bitPattern: word) >> 8) / 8_388_608)
          }
        case Self.pcm32:
          for at in stride(from: 0, to: bytes - 3, by: 4) {
            out.append(Float(raw.loadUnaligned(fromByteOffset: at, as: Int32.self)) / 2_147_483_648)
          }
        default:
          for at in stride(from: 0, to: bytes - 1, by: 2) {
            out.append(Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32768)
          }
        }
      }
    }
  }

  /// A media format's keys, which are Android's `MediaFormat` ones: the NDK's own constants for them
  /// are C globals, which Swift will not read from more than one thread.
  enum MediaKey {
    static let mime = "mime"
    static let sampleRate = "sample-rate"
    static let channelCount = "channel-count"
    static let bitRate = "bitrate"
    static let aacProfile = "aac-profile"
    static let pcmEncoding = "pcm-encoding"
  }

  /// Why the phone's media codecs could not read a file.
  enum MediaDecodingError: Error, CustomStringConvertible {
    case unreadable(String)
    /// Nothing in it Android recognises as audio.
    case notAudio
    /// Audio of a kind this phone has no decoder for.
    case noDecoder(String)
    /// Audio that decodes to nothing.
    case empty

    var description: String {
      switch self {
      case .unreadable(let path): "Could not open \(path)."
      case .notAudio: "Not an audio file this phone can read."
      case .noDecoder(let type): "This phone has no decoder for \(type)."
      case .empty: "An audio file with no audio in it."
      }
    }
  }
#endif
