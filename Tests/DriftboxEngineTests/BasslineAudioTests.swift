import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("bass.json").path)

/// Real 303 lines from the catalogue — slides, accents, ties, both waveforms — rendered through
/// the reference's `Bassline` in Chromium, scheduled the way its mix schedules them.
/// Needs `emit-audio.mjs` to have run.
struct BasslineAudioTests {
  @Test(.enabled(if: isGenerated))
  func linesSoundLikeTheReference() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("bass.json")), as: UTF8.self)
    let lines = try #require(JSONValue(parsing: text)?.array)
    #expect(lines.count == 3)

    var report = ""
    for line in lines.compactMap(\.object) {
      let name = try #require(line["name"]?.string)
      let sampleRate = try #require(line["sampleRate"]?.finite)
      let frames = Int(try #require(line["frames"]?.finite))
      let peak = try #require(line["peak"]?.finite)
      let file = try #require(line["file"]?.string)

      var bassline = Bassline(sampleRate: sampleRate)
      for entry in (line["notes"]?.array ?? []).compactMap(\.object) {
        let time = try #require(entry["time"]?.finite)
        let note = try bassNote(try #require(entry["note"]?.object))
        bassline.play(note, at: time, scheduledAt: entry["scheduledAt"]?.finite)
      }
      let mine = bassline.render(frames: frames)
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

      // Measured at -94 and -116dB for the sawtooth lines and -85dB for the square one. A ladder
      // this close to self-oscillation keeps whatever small difference it is given, so the bound
      // for a sawtooth is looser than a drum voice's; a square has the oscillator's own -75dB.
      let square = (line["notes"]?.array ?? []).contains {
        $0.object?["note"]?.object?["wave"]?.string == "square"
      }
      #expect(decibels <= (square ? -75 : -85), "\(name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }
}

private struct Malformed: Error {}

private func bassNote(_ json: JSONObject) throws -> BassNote {
  guard let frequency = json["frequency"]?.finite, let glide = json["glide"]?.finite,
    let retrigger = json["retrigger"]?.bool, let gate = json["gate"]?.finite, let gain = json["gain"]?.finite,
    let resonance = json["resonance"]?.finite, let filter = json["filter"]?.object,
    let peak = filter["peak"]?.finite, let base = filter["base"]?.finite, let decay = filter["decay"]?.finite
  else { throw Malformed() }
  return BassNote(
    frequency: frequency, glide: glide, glideFrom: json["glideFrom"]?.finite, retrigger: retrigger,
    gate: gate,
    wave: json["wave"]?.string == "square" ? .square : .sawtooth, gain: gain, resonance: resonance,
    filterPeak: peak, filterBase: base, filterDecay: decay)
}
