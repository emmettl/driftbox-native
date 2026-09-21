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
  /// Measured, per kind of voice, when this was written: noise through filters lands within one
  /// step of a 32-bit float (-135 to -142dB); a swept sine lands between -104 and -121dB, the gap
  /// being the browser's wavetable sine and its single-precision ramps against a true sine and
  /// double-precision ones. Chromium differs from *itself* by up to 5e-7 between two renders of one
  /// graph. -100dB is below all of that and some 40dB under anything audible.
  static let toleranceDecibels = -100.0

  @Test func theAudioFixturesAreThereWhenTheyMustBe() {
    #expect(isGenerated || !isRequired, "DRIFTBOX_REQUIRE_GENERATED is set and emit-audio.mjs has not run")
  }

  /// Each voice, rendered here and in Chromium, and subtracted.
  @Test(.enabled(if: isGenerated))
  func voicesSoundLikeTheReference() throws {
    var compared = 0
    var waiting: [String: String] = [:]
    for render in try Manifest.load().renders where render.case != "boundary" {
      let spec = try render.spec()
      guard
        let mine = VoiceRenderer.render(
          spec, voiceId: render.voice, sampleRate: render.sampleRate, frames: render.frames)
      else {
        waiting[render.voice] = VoiceRenderer.unsupported(spec)
        continue
      }
      let reference = try render.reference()
      #expect(reference.count == mine.count)

      let worst = zip(mine, reference).map { abs(Double($0) - Double($1)) }.max() ?? 0
      let decibels = worst > 0 ? 20 * log10(worst / render.peak) : -Double.infinity
      #expect(
        decibels <= Self.toleranceDecibels,
        "\(render.voice) \(render.case) is \(decibels)dB from the reference")
      compared += 1
    }

    // The renderer is being built one kind of node at a time. This is the list of what it renders
    // today; a voice leaves `waiting` by being compared, never by being skipped quietly.
    #expect(compared == 9 * 4)
    #expect(
      waiting.keys.sorted() == [
        "808.cb", "808.ch", "808.oh", "808.rs", "808.sd", "909.bd", "909.ch", "909.cp", "909.cr", "909.oh",
        "909.rd", "909.rim", "909.sd",
      ])
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
    let mine = try #require(
      VoiceRenderer.render(spec, voiceId: render.voice, sampleRate: render.sampleRate, frames: render.frames))
    let reference = try render.reference()

    let boundary = 2160
    let before =
      zip(mine[..<boundary], reference[..<boundary]).map { abs(Double($0) - Double($1)) }.max() ?? 1
    #expect(before < 1e-6, "identical until the tail is due")
    #expect(abs(mine[boundary]) < 1e-5, "silent on the frame before the tail starts")
    #expect(abs(reference[boundary]) > 0.01, "the reference lets a frame through at full level")
  }
}
