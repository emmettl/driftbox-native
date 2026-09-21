import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("sends.json").path)

private func floats(_ file: String) throws -> [Float] {
  try Data(contentsOf: generated.appendingPathComponent(file)).withUnsafeBytes { raw in
    (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
  }
}

private func fxParams(_ json: JSONObject?) -> FxParams {
  var fx = FxParams()
  for (knob, name) in FxParams.names.enumerated() { fx[knob] = json?[name]?.finite ?? fx[knob] }
  return fx
}

/// The send effects against the reference's own `Sends` in Chromium: one short burst in, and what
/// comes out is the effect and nothing else. Needs `emit-audio.mjs` to have run.
struct SendAudioTests {
  @Test(.enabled(if: isGenerated))
  func theDelaySoundsLikeTheReference() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("sends.json")), as: UTF8.self)
    let cases = try #require(JSONValue(parsing: text)?.array).compactMap(\.object).filter {
      $0["into"]?.string == "delay"
    }
    #expect(cases.count == 4)

    var report = ""
    for test in cases {
      let name = try #require(test["name"]?.string)
      let sampleRate = try #require(test["sampleRate"]?.finite)
      let frames = Int(try #require(test["frames"]?.finite))
      let peak = try #require(test["peak"]?.finite)
      let input = try floats(try #require(test["input"]?.string))
      let reference = try floats(try #require(test["left"]?.string))

      var delay = DelaySend(sampleRate: sampleRate)
      delay.update(fxParams(test["fx"]?.object), bpm: try #require(test["bpm"]?.finite), atFrame: 0)
      var updates = (test["updates"]?.array ?? []).compactMap(\.object)
      let startFrame = Int((test["startAt"]?.finite ?? 0) * sampleRate)
      var mine = [Float](repeating: 0, count: frames)
      for frame in 0..<frames {
        if let next = updates.first, let time = next["time"]?.finite, Int(time * sampleRate) <= frame {
          delay.update(fxParams(next["fx"]?.object), bpm: next["bpm"]?.finite ?? 120, atFrame: frame)
          updates.removeFirst()
        }
        let at = frame - startFrame
        mine[frame] = delay.process(at >= 0 && at < input.count ? input[at] : 0, frame: frame)
      }

      if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).f32")
        try mine.withUnsafeBytes { Data($0) }.write(to: url)
      }
      var worst = 0.0
      var worstAt = 0
      for (index, pair) in zip(mine, reference).enumerated() {
        let difference = abs(Double(pair.0) - Double(pair.1))
        if difference > worst {
          worst = difference
          worstAt = index
        }
      }
      let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
      report += "\(name): \(String(format: "%.1f", decibels))dB, worst at frame \(worstAt)\n"
      // Against the Chrome these were developed on — arm64 — every case measures -139 to -142dB.
      // Against an x64 Chrome only the settled delay does, because **the two Chromes do not agree
      // with each other** while a delay time is gliding: x64 steps `setTargetAtTime` four frames
      // at a time with differently rounded arithmetic, the delay time comes out a hundredth of a
      // sample different, and a click through a delay line is the most sensitive thing there is
      // to that. Measured between the two browsers on these same cases: -139, -119, -67, -19dB.
      // Nothing can be held to the reference more tightly than it holds to itself, so each bound
      // is that figure with a little room.
      let gliding = name.contains("gliding")
      let bound =
        gliding ? -15.0 : name.contains("retimed") ? -60.0 : name.contains("regenerating") ? -110.0 : -125.0
      #expect(decibels <= bound, "\(name) is \(decibels)dB from the reference")

      // What the two browsers do agree on, to within 0.3dB even mid-glide, is where the energy
      // is: the level of every stretch of the tail. That holds the shape of the glide, the loop
      // gain and the filter without caring about a hundredth of a sample.
      let block = 1024
      var energyGap = 0.0
      for start in stride(from: 0, to: frames - block, by: block) {
        let a = (mine[start..<start + block].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block))
          .squareRoot()
        let b =
          (reference[start..<start + block].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block))
          .squareRoot()
        if max(a, b) > peak * 1e-3 { energyGap = max(energyGap, abs(20 * log10(a / b))) }
      }
      #expect(energyGap <= 0.5, "\(name): a stretch of the tail is \(energyGap)dB out")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }

  @Test(.enabled(if: isGenerated))
  func theReverbSoundsLikeTheReference() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("sends.json")), as: UTF8.self)
    let cases = try #require(JSONValue(parsing: text)?.array).compactMap(\.object).filter {
      $0["into"]?.string == "reverb"
    }
    #expect(cases.count == 3)

    var report = ""
    for test in cases {
      let name = try #require(test["name"]?.string)
      let sampleRate = try #require(test["sampleRate"]?.finite)
      let frames = Int(try #require(test["frames"]?.finite))
      let peak = try #require(test["peak"]?.finite)
      let input = try floats(try #require(test["input"]?.string))
      let left = try floats(try #require(test["left"]?.string))
      let right = try floats(try #require(test["right"]?.string))

      let mine = ReverbSend.render(
        input, fx: fxParams(test["fx"]?.object), sampleRate: sampleRate, frames: frames)
      var worst = 0.0
      for frame in 0..<frames {
        worst = max(worst, abs(Double(mine.left[frame]) - Double(left[frame])))
        worst = max(worst, abs(Double(mine.right[frame]) - Double(right[frame])))
      }
      let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
      report += "\(name): \(String(format: "%.1f", decibels))dB\n"
      // Measured at -112 to -131dB against an arm64 Chrome and -97dB against an x64 one; the two
      // differ from each other by -99dB on the longest room. The browser convolves in single
      // precision, in stages, with whatever transform the platform has; this is one
      // double-precision transform.
      #expect(decibels <= -95, "\(name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }
}
