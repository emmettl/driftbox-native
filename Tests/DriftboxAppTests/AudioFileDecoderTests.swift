#if canImport(AVFoundation)
  import AVFoundation
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// Audio files as the Mac reads them into the rack, through Core Audio.
  struct AudioFileDecoderTests {
    static func sine(seconds: Double, frequency: Double, rate: Double, name: String? = nil) throws -> URL {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(name ?? "\(UUID()).wav")
      let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let frames = AVAudioFrameCount(seconds * rate)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      for channel in 0..<2 {
        for i in 0..<Int(frames) {
          buffer.floatChannelData![channel][i] = Float(
            0.5 * sin(2 * Double.pi * frequency * Double(i) / rate))
        }
      }
      try file.write(from: buffer)
      return url
    }

    /// A file at 44.1kHz, read into a rack at 48kHz, is as long and as high as it was.
    @Test func aFileIsReadAtTheRacksRateAndItsOwnPitch() throws {
      let url = try Self.sine(seconds: 0.5, frequency: 441, rate: 44100)
      defer { try? FileManager.default.removeItem(at: url) }
      let channels = try AudioFileDecoder().decode(url, sampleRate: 48000)
      #expect(channels.count == 2)
      #expect(abs(channels[0].count - 24000) < 64, "\(channels[0].count)")
      // 441 cycles a second is 220 or so rising zero crossings in half a second.
      var crossings = 0
      for i in 1..<channels[0].count where channels[0][i - 1] < 0 && channels[0][i] >= 0 { crossings += 1 }
      #expect(abs(crossings - 220) <= 2, "\(crossings)")
    }
  }
#endif
