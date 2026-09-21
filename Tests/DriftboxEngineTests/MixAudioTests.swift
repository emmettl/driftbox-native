import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("mixes.json").path)

private struct Mix: Decodable, CustomTestStringConvertible {
  let song: String
  let sampleRate: Double
  let start: Double
  let duration: Double
  let tail: Double
  let frames: Int
  let peak: Double
  let left: String
  let right: String
  /// A song document beside the render, for a mix that is not a catalogue song as it stands.
  var document: String?
  var testDescription: String { song }

  /// `DRIFTBOX_MIXES` points at another directory of renders with its own `mixes.json` — a way to
  /// take a mix apart when it differs: the same song with only its kick, only its hats.
  static let directory =
    ProcessInfo.processInfo.environment["DRIFTBOX_MIXES"].map { URL(fileURLWithPath: $0) } ?? generated

  static func all() throws -> [Mix] {
    let manifest = directory.appendingPathComponent("mixes.json")
    guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
    return try JSONDecoder().decode([Mix].self, from: Data(contentsOf: manifest))
  }
}

private func floats(_ file: String) throws -> [Float] {
  try Data(contentsOf: Mix.directory.appendingPathComponent(file)).withUnsafeBytes { raw in
    (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
  }
}

/// Whole mixes against the reference's own `renderMix` in Chromium: a window of each song, eight
/// bars in. Needs `emit-audio.mjs` to have run.
struct MixAudioTests {
  @Test(.enabled(if: isGenerated), arguments: try Mix.all())
  fileprivate func theMixSoundsLikeTheReference(mix: Mix) throws {
    let text =
      try mix.document.map {
        String(decoding: try Data(contentsOf: Mix.directory.appendingPathComponent($0)), as: UTF8.self)
      } ?? Fixtures.text("documents/\(mix.song).song.json")
    let song = try #require(SongCodec.decode(text))
    var options = SongRenderer.Options(
      sampleRate: mix.sampleRate, start: mix.start, duration: mix.duration, tail: mix.tail)
    options.emulatesBrowserSourceStart = true
    let mine = SongRenderer.render(song, options: options)
    let left = try floats(mix.left)
    let right = try floats(mix.right)
    #expect(mine.left.count == mix.frames)

    if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
      try mine.left.withUnsafeBytes { Data($0) }.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("mix \(mix.song).left.f32"))
    }

    let frames = min(mix.frames, mine.left.count)
    var worst = 0.0
    for frame in 0..<frames {
      worst = max(
        worst, abs(Double(mine.left[frame]) - Double(left[frame])),
        abs(Double(mine.right[frame]) - Double(right[frame])))
    }
    let decibels = worst > 0 ? 20 * log10(worst / mix.peak) : -Double.infinity

    // Every tenth of a second: how far apart the two are in level, and whether they differ at all.
    let block = Int(mix.sampleRate / 10)
    var levelGap = 0.0
    var differing = 0
    var blocks = 0
    for start in stride(from: 0, to: frames - block, by: block) {
      var mineEnergy = 0.0
      var theirEnergy = 0.0
      var apart = 0.0
      for frame in start..<start + block {
        mineEnergy += Double(mine.left[frame]) * Double(mine.left[frame])
        theirEnergy += Double(left[frame]) * Double(left[frame])
        apart = max(apart, abs(Double(mine.left[frame]) - Double(left[frame])))
      }
      blocks += 1
      if apart > mix.peak * 1e-3 { differing += 1 }
      if theirEnergy.squareRoot() > mix.peak * 0.01 * Double(block).squareRoot() {
        levelGap = max(levelGap, abs(10 * log10(mineEnergy / theirEnergy)))
      }
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil {
      print(
        "MIX \(mix.song): \(String(format: "%.1f", decibels))dB; level within \(String(format: "%.3f", levelGap))dB; \(differing) of \(blocks) stretches differ"
      )
    }

    // What every mix must do: sit at the reference's level all the way through, and be the same
    // signal for most of its length.
    #expect(levelGap <= 0.5, "\(mix.song): a tenth of a second is \(levelGap)dB out in level")
    #expect(
      differing * 10 <= blocks * 3,
      "\(mix.song): \(differing) of \(blocks) stretches differ by more than -60dB")

    // And sample for sample, where it can. Against the arm64 Chrome this was developed on, four
    // of these eight measure -80 to -98dB whole: every voice, both 303s, the sends, the compressor
    // and the idle pad, together.
    //
    // Against an x64 Chrome they measure what the two browsers measure against *each other*, which
    // for a whole mix is a good deal looser than for any one part of it: -81dB on orrery, -80 on
    // smallhours, -73 on hothouse, -56 on garage. Each bound is that, with a little room.
    //
    // The other four differ in a few short stretches each (3 to 17 tenths of a second out of 64),
    // and what happens there is the reference's doing, not understood yet. Bisected in the browser:
    // give a song a voice that is both panned and sending to the delay, and the *reference's own*
    // render of the 303 changes — before that voice has played a note — for the length of one bass
    // note after the first note scheduled from a suspend, and then goes back. This renderer gives
    // the same 303 either way. It is a channel-count effect inside Chromium's delay loop, and it
    // is not stable there either: these are the songs on which the two browsers disagree with each
    // other most, by -30 to -37dB. Until it is pinned down they are held to level and coverage.
    let bounds = ["orrery": -72.0, "smallhours": -72.0, "hothouse": -66.0, "garage": -50.0]
    if mix.document == nil, let bound = bounds[mix.song] {
      #expect(decibels <= bound, "\(mix.song) is \(decibels)dB from the reference")
    }
  }
}
