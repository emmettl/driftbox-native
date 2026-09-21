import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("probes.json").path)

/// One kind of node at a time, outside any voice: somewhere smaller to look when a voice differs
/// from the browser. Each probe is a hand-written spec that went through the reference's own
/// `renderVoice`. Needs `emit-audio.mjs` to have run.
struct ProbeTests {

  @Test(.enabled(if: isGenerated))
  func eachKindOfNodeSoundsLikeTheBrowsers() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("probes.json")), as: UTF8.self)
    let probes = try #require(JSONValue(parsing: text)?.array)
    #expect(probes.count == 9)

    var renderer = VoiceRenderer(sampleRate: 48000)
    var report = ""
    for probe in probes.compactMap(\.object) {
      let name = try #require(probe["name"]?.string)
      let frames = Int(try #require(probe["frames"]?.finite))
      let peak = try #require(probe["peak"]?.finite)
      let file = try #require(probe["file"]?.string)
      let spec = try voiceSpec(try #require(probe["spec"]?.object))

      let mine = renderer.render(spec, voiceId: "probe", frames: frames)
      let reference = try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
        (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
      }
      if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent((file as NSString).lastPathComponent)
        try mine.withUnsafeBytes { Data($0) }.write(to: url)
      }
      let worst = zip(mine, reference).map { abs(Double($0) - Double($1)) }.max() ?? 0
      let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
      report += "\(name): \(String(format: "%.1f", decibels))dB\n"
      #expect(
        decibels <= VoiceAudioTests.toleranceDecibels(for: spec),
        "\(name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }
}

// A spec from the reference's JSON.

private struct Malformed: Error {}

private func voiceSpec(_ json: JSONObject) throws -> VoiceSpec {
  guard let duration = json["duration"]?.finite, let gain = json["gain"]?.finite,
    let sources = json["sources"]?.array
  else { throw Malformed() }
  return VoiceSpec(
    duration: duration, sources: try sources.map(source), filter: try json["filter"]?.object.map(filter),
    drive: json["drive"]?.finite, gain: gain, pan: json["pan"]?.finite, trim: json["trim"]?.finite)
}

private func source(_ value: JSONValue) throws -> Source {
  guard let json = value.object, let gain = json["gain"]?.finite, let amp = json["amp"]?.array else {
    throw Malformed()
  }
  let generator: Source.Generator
  if json["kind"]?.string == "osc" {
    let type: Waveform =
      switch json["type"]?.string {
      case "triangle": .triangle
      case "square": .square
      case "sawtooth": .sawtooth
      default: .sine
      }
    guard let frequency = json["frequency"]?.finite else { throw Malformed() }
    generator = .oscillator(
      Oscillator(
        type: type, frequency: frequency, pitch: try json["pitch"]?.array.map { try $0.map(breakpoint) }))
  } else {
    generator = .noise(
      Noise(
        sampleRate: json["sampleRate"]?.finite, bitDepth: json["bitDepth"]?.finite,
        seed: json["seed"]?.finite,
        playbackRate: json["playbackRate"]?.finite))
  }
  return Source(
    generator, gain: gain, amp: try amp.map(breakpoint), filter: try json["filter"]?.object.map(filter),
    delay: json["delay"]?.finite)
}

private func filter(_ json: JSONObject) throws -> FilterSpec {
  guard let frequency = json["frequency"]?.finite else { throw Malformed() }
  let type: FilterKind =
    switch json["type"]?.string {
    case "highpass": .highpass
    case "bandpass": .bandpass
    default: .lowpass
    }
  return FilterSpec(
    type: type, frequency: frequency, q: json["Q"]?.finite,
    envelope: try json["envelope"]?.array.map { try $0.map(breakpoint) })
}

private func breakpoint(_ value: JSONValue) throws -> Breakpoint {
  guard let json = value.object, let to = json["to"]?.finite, let at = json["at"]?.finite else {
    throw Malformed()
  }
  let curve: Curve? =
    switch json["curve"]?.string {
    case "lin": .linear
    case "exp": .exponential
    default: nil
    }
  return Breakpoint(to: to, at: at, curve: curve)
}
