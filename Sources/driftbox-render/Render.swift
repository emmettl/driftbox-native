import DriftboxDocument
import DriftboxEngine
import Foundation

/// Renders a song document to a WAV file, offline. The listening half of conformance: the tests
/// say how far a render is from the reference's, and this is how to hear what that sounds like.
///
///     swift run -c release driftbox-render conformance/fixtures/documents/acid.song.json acid.wav
///     swift run -c release driftbox-render song.json out.wav --start 15.2 --duration 8 --rate 48000
@main
struct Render {
  static func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) -> Double? {
      guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
      defer { arguments.removeSubrange(index...index + 1) }
      return Double(arguments[index + 1])
    }
    let start = option("--start") ?? 0
    let duration = option("--duration")
    let sampleRate = option("--rate") ?? 48000
    let tail = option("--tail") ?? 4

    guard arguments.count == 2 else {
      let usage =
        "usage: driftbox-render <song.json> <out.wav> [--start s] [--duration s] [--rate hz] [--tail s]\n"
      FileHandle.standardError.write(Data(usage.utf8))
      exit(64)
    }
    let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: arguments[0])), as: UTF8.self)
    guard let song = SongCodec.decode(text) else {
      FileHandle.standardError.write(Data("\(arguments[0]) is not a song\n".utf8))
      exit(65)
    }

    let began = Date()
    let audio = SongRenderer.render(
      song, options: .init(sampleRate: sampleRate, start: start, duration: duration, tail: tail))
    try wav(audio, sampleRate: sampleRate).write(to: URL(fileURLWithPath: arguments[1]))

    let seconds = Double(audio.left.count) / sampleRate
    let took = Date().timeIntervalSince(began)
    print(
      String(
        format: "%.1fs of audio in %.1fs (%.0fx real time) -> %@", seconds, took, seconds / took, arguments[1]
      ))
  }

  /// 32-bit float, interleaved: nothing is lost on the way to the file.
  static func wav(_ audio: VoiceRenderer.Stereo, sampleRate: Double) -> Data {
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
