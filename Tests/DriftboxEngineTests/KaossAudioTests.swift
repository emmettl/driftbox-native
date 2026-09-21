import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("kaoss.json").path)

private func floats(_ file: String) throws -> [Float] {
  try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
    (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
  }
}

/// The performance filter against the reference's own `Kaoss` in Chromium: idle, and through
/// three gestures. Needs `emit-audio.mjs` to have run.
struct KaossAudioTests {
  @Test(.enabled(if: isGenerated))
  func thePadSoundsLikeTheReference() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("kaoss.json")), as: UTF8.self)
    let cases = try #require(JSONValue(parsing: text)?.array).compactMap(\.object)
    #expect(cases.count == 4)

    var report = ""
    for test in cases {
      let name = try #require(test["name"]?.string)
      let sampleRate = try #require(test["sampleRate"]?.finite)
      let inLeft = try floats(try #require(test["inputLeft"]?.string))
      let inRight = try floats(try #require(test["inputRight"]?.string))
      let left = try floats(try #require(test["left"]?.string))
      let right = try floats(try #require(test["right"]?.string))
      var moves = (test["moves"]?.array ?? []).compactMap(\.object)

      var kaoss = Kaoss(sampleRate: sampleRate)
      var mine = [Float](repeating: 0, count: inLeft.count)
      var worst = 0.0
      var worstAt = 0
      var peak = 0.0
      for frame in 0..<inLeft.count {
        if let move = moves.first, let at = move["frame"]?.finite, Int(at) <= frame {
          if move["release"]?.bool == true {
            kaoss.release(atFrame: frame)
          } else {
            kaoss.set(x: move["x"]?.finite ?? 0.5, y: move["y"]?.finite ?? 0, atFrame: frame)
          }
          moves.removeFirst()
        }
        let out = kaoss.process(left: inLeft[frame], right: inRight[frame], frame: frame)
        mine[frame] = out.left
        let difference = max(
          abs(Double(out.left) - Double(left[frame])), abs(Double(out.right) - Double(right[frame])))
        if difference > worst {
          worst = difference
          worstAt = frame
        }
        peak = max(peak, abs(Double(left[frame])), abs(Double(right[frame])))
      }
      if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
        try mine.withUnsafeBytes { Data($0) }.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("kaoss \(name).f32"))
      }
      let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
      report += "\(name): \(String(format: "%.1f", decibels))dB, worst at frame \(worstAt)\n"
      // Against the arm64 Chrome this was developed on, idle — the case every mix goes through —
      // measures -141dB, and the gestures -78 to -98dB: tones match to a step of a float all the
      // way through a glide, and what is left shows only on full-band noise while a release is
      // gliding, which is not understood and, for a control nobody touches during a render, not
      // chased.
      //
      // Against an x64 Chrome everything measures about -76dB, idle included, because that is how
      // far the two browsers are from *each other*: -76, -74, -86 and -70dB on these four cases.
      // A high-pass at 20Hz has its poles almost on top of each other, which is the hardest thing
      // to ask of a biquad's arithmetic, and the two builds do that arithmetic differently. The
      // bounds are the browsers' own disagreement with a little room.
      #expect(decibels <= (name == "idle" ? -72 : -66), "\(name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }

  @Test func theMiddleOfThePadLeavesBothFiltersWideOpen() {
    let open = Kaoss.cutoffs(x: 0.5)
    #expect(open.low == 20000 && open.high == 20)
    #expect(Kaoss.cutoffs(x: 0).low == 90)
    #expect(Kaoss.cutoffs(x: 1).high == 6000)
    #expect(Kaoss.cutoffs(x: 0.25).high == 20)
    #expect(Kaoss.resonance(y: 1) == 12)
  }
}
