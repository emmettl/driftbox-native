import DriftboxEngine

// `Data` is all this takes, and the essentials have it without the rest of Foundation — which on
// Android is a libdispatch and 30MB of ICU data.
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A stereo render as a WAV file: 32-bit float, interleaved, so nothing is lost on the way out.
public enum WAV {
  public static func data(_ audio: VoiceRenderer.Stereo, sampleRate: Double) -> Data {
    var body = Data(capacity: audio.left.count * 8)
    for frame in 0..<audio.left.count {
      withUnsafeBytes(of: audio.left[frame].bitPattern.littleEndian) { body.append(contentsOf: $0) }
      withUnsafeBytes(of: audio.right[frame].bitPattern.littleEndian) { body.append(contentsOf: $0) }
    }
    var header = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    header.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + body.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))  // IEEE float
    append(UInt16(2))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate) * 8)
    append(UInt16(8))
    append(UInt16(32))
    header.append(contentsOf: Array("data".utf8))
    append(UInt32(body.count))
    return header + body
  }
}
