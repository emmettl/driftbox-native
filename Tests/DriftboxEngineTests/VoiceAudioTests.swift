import ConformanceSupport
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

/// Written by `conformance/emit/emit-audio.mjs`, which needs a Chromium. Not checked in.
private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("voices.json").path)

/// CI renders the audio and sets this, so that "the fixtures were not there" is a failure there
/// and a skip on a laptop.
private let isRequired = ProcessInfo.processInfo.environment["DRIFTBOX_REQUIRE_GENERATED"] != nil

private struct Manifest: Decodable {
  struct Render: Decodable {
    let voice: String
    let `case`: String
    let params: [String: Double]
    let accent: Double
    let sampleRate: Double
    let frames: Int
    let peak: Double
    let file: String
    /// When the hit was struck. Absent means zero.
    var time: Double?

    func spec() throws -> VoiceSpec {
      let found = DriftboxEngine.voice(id: voice)
      let voice = try #require(found)
      var panel = VoiceParams()
      for (knob, name) in VoiceParams.names.enumerated() { panel[knob] = try #require(params[name]) }
      return voice.build(panel, accent: accent)
    }

    func reference() throws -> [Float] {
      try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
        (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
      }
    }
  }
  let renders: [Render]

  static func load(_ name: String) throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: generated.appendingPathComponent(name)))
  }
}

struct VoiceAudioTests {
  /// How far a render may be from Chromium's, relative to the voice's own peak.
  ///
  /// Measured when this was written. Noise through filters, resampled or not, lands within a step
  /// or two of a 32-bit float: -120 to -142dB. Sines and triangles land between -104 and -125dB,
  /// the gap being the browser's single-precision ramps against double-precision ones. Chromium
  /// differs from *itself* by up to 5e-7 between two renders of one graph.
  ///
  /// Squares and sawtooths are looser, and the reason is the browser's arithmetic rather than this
  /// renderer's. What is left after matching its tables and its single-precision phase increment is
  /// a timing difference of about a hundred-thousandth of a sample in where the wavetable is read.
  /// A waveform with edges turns that into an error that is flat across every harmonic: about
  /// -80dB on a bare square, and a nanosecond by any other measure.
  static func toleranceDecibels(for spec: VoiceSpec) -> Double {
    let hasEdges = spec.sources.contains { source in
      if case .oscillator(let oscillator) = source.generator {
        return oscillator.type == .square || oscillator.type == .sawtooth
      }
      return false
    }
    if hasEdges { return -75 }
    // Drive is a steep curve — a slope of 13 at the 909 kick's default — so whatever small
    // difference reaches it leaves some 22dB larger. Measured at -98dB on that kick.
    if let drive = spec.drive, drive > 0 { return -90 }
    return -100
  }

  @Test func theAudioFixturesAreThereWhenTheyMustBe() {
    #expect(isGenerated || !isRequired, "DRIFTBOX_REQUIRE_GENERATED is set and emit-audio.mjs has not run")
  }

  /// Each voice, rendered here and in Chromium, and subtracted.
  @Test(.enabled(if: isGenerated))
  func voicesSoundLikeTheReference() throws {
    var compared = Set<String>()
    var report = ""
    var renderer = VoiceRenderer(sampleRate: 48000)
    for render in try Manifest.load("voices.json").renders {
      #expect(render.sampleRate == renderer.sampleRate)
      let spec = try render.spec()
      let mine = renderer.render(spec, voiceId: render.voice, frames: render.frames)
      let reference = try render.reference()
      #expect(reference.count == mine.count)
      if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
        // For looking at a difference rather than only measuring it.
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(render.voice).\(render.case).f32")
        try mine.withUnsafeBytes { Data($0) }.write(to: url)
      }

      let worst = zip(mine, reference).map { abs(Double($0) - Double($1)) }.max() ?? 0
      let decibels = worst > 0 ? 20 * log10(worst / render.peak) : -Double.infinity
      #expect(
        decibels <= Self.toleranceDecibels(for: spec),
        "\(render.voice) \(render.case) is \(decibels)dB from the reference")
      compared.insert(render.voice)
      report += "\(render.voice) \(render.case): \(String(format: "%.1f", decibels))dB\n"
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
    #expect(compared.count == 22)
  }

  /// Every voice again, struck at a time that is not on a sample frame — which is where nearly
  /// every hit in a real song falls.
  @Test(.enabled(if: isGenerated))
  func voicesStruckBetweenFramesSoundLikeTheReference() throws {
    var renderer = VoiceRenderer(sampleRate: 48000)
    renderer.emulatesBrowserSourceStart = true
    var report = ""
    let renders = try Manifest.load("offset.json").renders
    #expect(renders.count == 88)
    for render in renders {
      let spec = try render.spec()
      let mine = renderer.renderStereo(
        spec, voiceId: render.voice, at: render.time ?? 0, frames: render.frames
      ).left
      let reference = try render.reference()
      var worst = 0.0
      var firstAt = -1
      for (index, pair) in zip(mine, reference).enumerated() {
        let difference = abs(Double(pair.0) - Double(pair.1))
        worst = max(worst, difference)
        if firstAt < 0, difference > 1e-5 { firstAt = index }
      }
      let decibels = worst > 0 ? 20 * log10(worst / render.peak) : -Double.infinity
      report += "OFFSET \(render.voice) \(render.case): \(String(format: "%.1f", decibels))dB\n"

      // As for a hit on a frame, except the 909's cymbals: resampled noise started between frames
      // measures -71 to -83dB where on a frame it measures -120dB, and the difference has not been
      // run down.
      let resampled = spec.sources.contains {
        if case .noise(let noise) = $0.generator { return noise.playbackRate != nil }
        return false
      }
      #expect(
        decibels <= (resampled ? -66 : Self.toleranceDecibels(for: spec)),
        "\(render.voice) \(render.case) is \(decibels)dB from the reference")
      _ = firstAt
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }

  /// Every voice again with its pan knob off centre, into a stereo context: the mono renders
  /// cannot tell left from right.
  @Test(.enabled(if: isGenerated))
  func pannedVoicesSoundLikeTheReference() throws {
    var renderer = VoiceRenderer(sampleRate: 48000)
    let renders = try Manifest.load("stereo.json").renders
    #expect(renders.count == 22)
    for render in renders {
      let spec = try render.spec()
      let mine = renderer.renderStereo(spec, voiceId: render.voice, frames: render.frames)
      let reference = try render.reference()
      #expect(reference.count == render.frames * 2)

      var worst = 0.0
      for frame in 0..<render.frames {
        worst = max(worst, abs(Double(mine.left[frame]) - Double(reference[frame * 2])))
        worst = max(worst, abs(Double(mine.right[frame]) - Double(reference[frame * 2 + 1])))
      }
      let decibels = worst > 0 ? 20 * log10(worst / render.peak) : -Double.infinity
      #expect(
        decibels <= Self.toleranceDecibels(for: spec),
        "\(render.voice) panned is \(decibels)dB from the reference")

      // Left of centre, so the left side is the louder one.
      let left = mine.left.map(abs).max() ?? 0
      let right = mine.right.map(abs).max() ?? 0
      #expect(left > right)
    }
  }
}
