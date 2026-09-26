#if os(Android)
  import Android
  import CMedia
  import DriftboxRackSession
  import FoundationEssentials

  /// `MediaDecoder` on the phone: a second of two tones, 440Hz on the left and 660Hz on the right,
  /// written as a WAV and read back through the phone's codecs, which must give the WAV reader's
  /// samples exactly; then encoded as AAC by the phone's own encoder and decoded at the rack's
  /// rate, which must give the same tones, as long, at their own pitch.
  enum DecodingCheck {
    static let rate = 44100
    static let tones: [Double] = [440, 660]

    static func run(in folder: URL) -> [String] {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let samples = (0..<rate).flatMap { frame in
        tones.map { Int16((sin(2 * .pi * $0 * Double(frame) / Double(rate)) * 0.5 * 32767).rounded()) }
      }
      var lines: [String] = []
      func check(_ passed: Bool, _ what: String) { lines.append("\(passed ? "PASS" : "FAIL") \(what)") }

      let wav = folder.appending(path: "tones.wav")
      do {
        let bytes = self.wav(samples)
        try bytes.write(to: wav)
        let exact = try WAVDecoder().decode(bytes, sampleRate: Double(rate))
        let read = try MediaDecoder.read(wav.path)
        check(
          read.rate == Double(rate) && read.channels == exact,
          "a WAV through the phone's codecs is the WAV reader's, sample for sample")
      } catch {
        check(false, "a WAV through the phone's codecs: \(error)")
      }

      let aac = folder.appending(path: "tones.m4a")
      guard encode(samples, to: aac.path) else {
        check(false, "the phone's AAC encoder wrote nothing")
        return lines
      }
      do {
        let decoded = try MediaDecoder().decode(aac, sampleRate: RackCheck.sampleRate)
        let frames = decoded.first?.count ?? 0
        // An AAC encoder pads the start and the end by a frame or two, which a decoder may keep.
        check(
          decoded.count == 2 && abs(frames - Int(RackCheck.sampleRate)) < 4800,
          "AAC decodes to two channels of a second: \(decoded.count) of \(frames) frames")
        for (channel, tone) in zip(decoded, tones) {
          let heard = pitch(channel, sampleRate: RackCheck.sampleRate)
          let peak = channel.reduce(0) { max($0, abs($1)) }
          check(
            abs(heard - tone) < tone * 0.01 && peak > 0.4 && peak < 0.6,
            "AAC's \(Int(tone))Hz tone comes back at \(RackCheck.tenths(heard))Hz, peak "
              + RackDisplay.fixed(Double(peak), 3))
        }
      } catch {
        check(false, "AAC decodes: \(error)")
      }
      return lines
    }

    /// Cycles a second in the middle half of `samples`, counted by where it rises through zero.
    static func pitch(_ samples: [Float], sampleRate: Double) -> Double {
      let from = samples.count / 4
      let to = samples.count * 3 / 4
      guard to > from + 1 else { return 0 }
      var first: Int?
      var last = 0
      var rises = 0
      for index in from + 1..<to where samples[index - 1] < 0 && samples[index] >= 0 {
        if first == nil { first = index } else { rises += 1 }
        last = index
      }
      guard let first, last > first else { return 0 }
      return Double(rises) * sampleRate / Double(last - first)
    }

    /// Interleaved 16-bit samples as a WAV file's bytes.
    static func wav(_ samples: [Int16]) -> Data {
      var data = Data()
      func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
      }
      let channels = tones.count
      data.append(contentsOf: Array("RIFF".utf8))
      put(UInt32(36 + samples.count * 2))
      data.append(contentsOf: Array("WAVEfmt ".utf8))
      put(UInt32(16))
      put(UInt16(1))
      put(UInt16(channels))
      put(UInt32(rate))
      put(UInt32(rate * channels * 2))
      put(UInt16(channels * 2))
      put(UInt16(16))
      data.append(contentsOf: Array("data".utf8))
      put(UInt32(samples.count * 2))
      for sample in samples { put(sample) }
      return data
    }

    /// Interleaved 16-bit samples as AAC in an MPEG-4 file at `path`, by the phone's own encoder.
    static func encode(_ samples: [Int16], to path: String) -> Bool {
      let channels = tones.count
      guard let format = AMediaFormat_new() else { return false }
      defer { AMediaFormat_delete(format) }
      AMediaFormat_setString(format, MediaKey.mime, "audio/mp4a-latm")
      AMediaFormat_setInt32(format, MediaKey.sampleRate, Int32(rate))
      AMediaFormat_setInt32(format, MediaKey.channelCount, Int32(channels))
      AMediaFormat_setInt32(format, MediaKey.bitRate, 128_000)
      // AAC-LC.
      AMediaFormat_setInt32(format, MediaKey.aacProfile, 2)
      guard let codec = AMediaCodec_createEncoderByType("audio/mp4a-latm") else { return false }
      defer { AMediaCodec_delete(codec) }
      guard
        AMediaCodec_configure(codec, format, nil, nil, UInt32(AMEDIACODEC_CONFIGURE_FLAG_ENCODE))
          == AMEDIA_OK,
        AMediaCodec_start(codec) == AMEDIA_OK
      else { return false }
      defer { AMediaCodec_stop(codec) }
      let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o644)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      guard let muxer = AMediaMuxer_new(fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) else { return false }
      defer { AMediaMuxer_delete(muxer) }

      var sent = 0
      var fed = false
      var track = -1
      var written = 0
      var idle = 0
      while idle < 200 {
        if !fed {
          let slot = AMediaCodec_dequeueInputBuffer(codec, 10_000)
          var capacity = 0
          if slot >= 0, let buffer = AMediaCodec_getInputBuffer(codec, Int(slot), &capacity) {
            let count = min(samples.count - sent, capacity / 2 / channels * channels)
            let time = UInt64(sent / channels) * 1_000_000 / UInt64(rate)
            if count <= 0 {
              AMediaCodec_queueInputBuffer(
                codec, Int(slot), 0, 0, time, UInt32(AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM))
              fed = true
            } else {
              samples.withUnsafeBytes { memcpy(buffer, $0.baseAddress! + sent * 2, count * 2) }
              AMediaCodec_queueInputBuffer(codec, Int(slot), 0, count * 2, time, 0)
              sent += count
            }
          }
        }
        var info = AMediaCodecBufferInfo()
        let slot = AMediaCodec_dequeueOutputBuffer(codec, &info, 10_000)
        if slot >= 0 {
          idle = 0
          let config = info.flags & UInt32(AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) != 0
          if !config, track >= 0, info.size > 0,
            let buffer = AMediaCodec_getOutputBuffer(codec, Int(slot), nil)
          {
            if AMediaMuxer_writeSampleData(muxer, Int(track), buffer, &info) == AMEDIA_OK { written += 1 }
          }
          AMediaCodec_releaseOutputBuffer(codec, Int(slot), false)
          if info.flags & UInt32(AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0 { break }
        } else if slot == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED {
          guard let output = AMediaCodec_getOutputFormat(codec) else { return false }
          track = AMediaMuxer_addTrack(muxer, output)
          AMediaFormat_delete(output)
          guard track >= 0, AMediaMuxer_start(muxer) == AMEDIA_OK else { return false }
        } else if fed {
          idle += 1
        }
      }
      return track >= 0 && AMediaMuxer_stop(muxer) == AMEDIA_OK && written > 0
    }
  }
#endif
