import Foundation
import Testing

@testable import DriftboxRackSession

/// WAV files read in Swift alone: each sample size and encoding, chunks it has no use for, a
/// file at another rate, and a file that is not audio at all.
struct WAVDecoderTests {
  @Test func sixteenBitMonoIsReadAsItWasWritten() throws {
    let file = WAV.file(
      WAV.format(tag: 1, channels: 1, rate: 48000, bits: 16),
      WAV.chunk("data", [0, 16384, -32768, 32767].flatMap { WAV.le($0, 2) }))
    let channels = try decode(file)
    #expect(channels == [[0, 0.5, -1, Float(32767) / 32768]])
  }

  @Test func twentyFourBitStereoKeepsItsChannelsApart() throws {
    let frames = [(0x40_0000, -0x40_0000), (-0x80_0000, 0x7F_FFFF), (0, 0x20_0000)]
    let file = WAV.file(
      WAV.format(tag: 1, channels: 2, rate: 48000, bits: 24),
      WAV.chunk("data", frames.flatMap { WAV.le($0.0, 3) + WAV.le($0.1, 3) }))
    let channels = try decode(file)
    #expect(channels.count == 2)
    #expect(channels[0] == [0.5, -1, 0])
    #expect(channels[1] == [-0.5, Float(0x7F_FFFF) / 8_388_608, 0.25])
  }

  @Test func floatingPointIsReadPlainOrExtensible() throws {
    let samples: [Float] = [0.25, -0.75, 1.5, 0]
    let audio = WAV.chunk("data", samples.flatMap { WAV.le(Int($0.bitPattern), 4) })
    let plain = WAV.file(WAV.format(tag: 3, channels: 1, rate: 48000, bits: 32), audio)
    #expect(try decode(plain) == [samples])
    let extensible = WAV.file(WAV.extensible(subformat: 3, channels: 1, rate: 48000, bits: 32), audio)
    #expect(try decode(extensible) == [samples])
    let doubles = WAV.chunk(
      "data", samples.flatMap { WAV.le(Int(truncatingIfNeeded: Double($0).bitPattern), 8) })
    let wide = WAV.file(WAV.format(tag: 3, channels: 1, rate: 48000, bits: 64), doubles)
    #expect(try decode(wide) == [samples])
  }

  /// A chunk of odd length before the audio is stepped over, pad byte and all.
  @Test func chunksItDoesNotKnowAreSkipped() throws {
    let file = WAV.file(
      WAV.format(tag: 1, channels: 1, rate: 48000, bits: 16),
      WAV.chunk("LIST", Array("INFOx".utf8)),
      WAV.chunk("bext", [UInt8](repeating: 7, count: 12)),
      WAV.chunk("data", [16384, -16384].flatMap { WAV.le($0, 2) }))
    #expect(try decode(file) == [[0.5, -0.5]])
  }

  /// A file at 44.1kHz, read into a rack at 48kHz, is as long as it was and on the same line.
  @Test func aFileAtAnotherRateIsResampled() throws {
    let ramp = (0..<4410).map { $0 }
    let file = WAV.file(
      WAV.format(tag: 1, channels: 1, rate: 44100, bits: 16),
      WAV.chunk("data", ramp.flatMap { WAV.le($0, 2) }))
    let channels = try decode(file, at: 48000)
    #expect(channels.count == 1)
    #expect(channels[0].count == 4800)
    // Output sample 160 falls exactly on input sample 147; sample 1 between the first two.
    #expect(abs(channels[0][160] - 147 / 32768) < 1e-6)
    #expect(abs(channels[0][1] - 0.91875 / 32768) < 1e-6)
    #expect(try decode(file, at: 44100)[0].count == 4410)
  }

  @Test func whatItCannotReadItSaysWhy() throws {
    #expect(throws: WAVDecodingError.notWAV) { try decode(Data("not audio".utf8)) }
    let adpcm = WAV.file(WAV.format(tag: 2, channels: 1, rate: 48000, bits: 4), WAV.chunk("data", [0, 0]))
    #expect(throws: WAVDecodingError.unsupported(formatTag: 2, bitsPerSample: 4)) { try decode(adpcm) }
    let silent = WAV.file(WAV.format(tag: 1, channels: 1, rate: 48000, bits: 16))
    #expect(throws: WAVDecodingError.missingData) { try decode(silent) }
  }

  /// `data` written to a temporary file and read back at `rate`.
  func decode(_ data: Data, at rate: Double = 48000) throws -> [[Float]] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try WAVDecoder().decode(url, sampleRate: rate)
  }
}

/// WAV files built byte by byte.
private enum WAV {
  /// `value` in `count` bytes, little-endian, negative numbers as two's complement.
  static func le(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
  }

  /// An id, a size, the body, and a pad byte after a body of odd length.
  static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + le(body.count, 4) + body + (body.count % 2 == 1 ? [0] : [])
  }

  static func format(tag: Int, channels: Int, rate: Int, bits: Int) -> [UInt8] {
    chunk("fmt ", header(tag: tag, channels: channels, rate: rate, bits: bits))
  }

  /// WAVE_FORMAT_EXTENSIBLE, with `subformat` at the head of the standard GUID.
  static func extensible(subformat: Int, channels: Int, rate: Int, bits: Int) -> [UInt8] {
    let guid: [UInt8] = le(subformat, 2) + [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
    // After the plain header: the size of what follows, the valid bits, the speaker mask.
    let more: [UInt8] = le(22, 2) + le(bits, 2) + le(0, 4) + guid
    return chunk("fmt ", header(tag: 0xFFFE, channels: channels, rate: rate, bits: bits) + more)
  }

  static func file(_ chunks: [UInt8]...) -> Data {
    let body = Array("WAVE".utf8) + chunks.flatMap { $0 }
    return Data(Array("RIFF".utf8) + le(body.count, 4) + body)
  }

  private static func header(tag: Int, channels: Int, rate: Int, bits: Int) -> [UInt8] {
    let block = channels * max(1, bits / 8)
    return le(tag, 2) + le(channels, 2) + le(rate, 4) + le(rate * block, 4) + le(block, 2) + le(bits, 2)
  }
}
