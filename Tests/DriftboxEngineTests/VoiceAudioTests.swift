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

  static func load() throws -> Manifest {
    try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: generated.appendingPathComponent("voices.json")))
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
    return hasEdges ? -75 : -100
  }

  @Test func theAudioFixturesAreThereWhenTheyMustBe() {
    #expect(isGenerated || !isRequired, "DRIFTBOX_REQUIRE_GENERATED is set and emit-audio.mjs has not run")
  }

  /// Each voice, rendered here and in Chromium, and subtracted.
  @Test(.enabled(if: isGenerated))
  func voicesSoundLikeTheReference() throws {
    var compared = 0
    var waiting: [String: String] = [:]
    var report = ""
    var renderer = VoiceRenderer(sampleRate: 48000)
    for render in try Manifest.load().renders where render.case != "boundary" {
      let spec = try render.spec()
      guard
        render.sampleRate == renderer.sampleRate,
        let mine = renderer.render(spec, voiceId: render.voice, frames: render.frames)
      else {
        waiting[render.voice] = VoiceRenderer.unsupported(spec)
        continue
      }
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
      compared += 1
      report += "\(render.voice) \(render.case): \(String(format: "%.1f", decibels))dB\n"
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }

    // The renderer is being built one kind of node at a time. This is the list of what it renders
    // today; a voice leaves `waiting` by being compared, never by being skipped quietly.
    #expect(compared == 19 * 4)
    #expect(
      waiting.keys.sorted() == ["909.bd", "909.cp", "909.sd"])
  }

  /// A place where the reference is wrong, kept so that it is known rather than rediscovered.
  ///
  /// At colour 0.9 the 808 clap's tail is due to start 5e-13 of a frame after frame 2160. Chromium
  /// rounds the *source* onto frame 2160, but the gain envelope's first event is still that sliver
  /// in the future — and before its first event a `GainNode` sits at its default of 1. So one frame
  /// of noise goes out at full level: a click, some 40 times louder than anything around it, that
  /// the band-pass then rings on. It depends on the knob, the sample rate and the hit's start time
  /// all lining up, which is why it has gone unheard.
  ///
  /// This renderer starts the tail silent, as the envelope says. If this test ever fails because
  /// the two agree, the reference has been fixed and the test should go.
  @Test(.enabled(if: isGenerated))
  func theReferenceClicks() throws {
    let render = try #require(try Manifest.load().renders.first { $0.case == "boundary" })
    let spec = try render.spec()
    var renderer = VoiceRenderer(sampleRate: render.sampleRate)
    let rendered = renderer.render(spec, voiceId: render.voice, frames: render.frames)
    let mine = try #require(rendered)
    let reference = try render.reference()

    let boundary = 2160
    let before =
      zip(mine[..<boundary], reference[..<boundary]).map { abs(Double($0) - Double($1)) }.max() ?? 1
    #expect(before < 1e-6, "identical until the tail is due")
    #expect(abs(mine[boundary]) < 1e-5, "silent on the frame before the tail starts")
    #expect(abs(reference[boundary]) > 0.01, "the reference lets a frame through at full level")
  }
}
