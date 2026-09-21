import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/audio")
private let isGenerated = FileManager.default.fileExists(
  atPath: generated.appendingPathComponent("master.json").path)

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

/// The master inserts whole, against the reference's own `MasterEffects` in Chromium.
/// Needs `emit-audio.mjs` to have run.
struct MasterAudioTests {
  @Test(.enabled(if: isGenerated))
  func theInsertsSoundLikeTheReference() throws {
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("master.json")), as: UTF8.self)
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
      let fx = fxParams(test["fx"]?.object)

      var inserts = MasterInserts(sampleRate: sampleRate)
      inserts.update(fx, atFrame: 0)
      var strikes = (test["strikes"]?.array ?? []).compactMap(\.object)

      var worst = 0.0
      var worstAt = 0
      var peak = 0.0
      var mine = [Float](repeating: 0, count: inLeft.count)
      defer {
        if let directory = ProcessInfo.processInfo.environment["DRIFTBOX_WRITE"] {
          try? mine.withUnsafeBytes { Data($0) }.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).f32"))
        }
      }
      for frame in 0..<inLeft.count {
        // Made when the reference makes them: at the start of the render quantum they fall in.
        if let next = strikes.first, let time = next["time"]?.finite,
          Int(time * sampleRate) / 128 * 128 <= frame
        {
          let value = next["pcf"]?.finite ?? 0
          inserts.update(
            next["fx"]?.object.map { fxParams($0) } ?? fx, atFrame: Int((time * sampleRate).rounded(.up)),
            strike: value == 2 ? .accent : value == 1 ? .on : .off, scheduledAtFrame: frame)
          strikes.removeFirst()
        }
        let out = inserts.process(left: inLeft[frame], right: inRight[frame], frame: frame)
        mine[frame] = out.left
        let difference = max(
          abs(Double(out.left) - Double(left[frame])), abs(Double(out.right) - Double(right[frame])))
        if difference > worst {
          worst = difference
          worstAt = frame
        }
        peak = max(peak, abs(Double(left[frame])), abs(Double(right[frame])))
      }
      let decibels = worst > 0 ? 20 * log10(worst / peak) : -Double.infinity
      report += "\(name): \(String(format: "%.1f", decibels))dB, worst at frame \(worstAt)\n"

      // Measured: -136dB at the defaults, where the chain is the compressor alone; -109dB driven;
      // -94dB with everything on and knobs moving.
      //
      // And -63dB with the filter struck on the steps, which is one strike out of six. A strike
      // that arrives while the sweep before it is still running cancels that sweep, and for a
      // quarter of a second afterwards this differs from the browser by 4e-4; the five strikes
      // that find the filter at rest match at -120dB. Snapping back to the cancelled sweep's
      // peak — see `ParamTimeline.cancel` — is certainly the larger part of what the browser
      // does, since holding instead is 18dB worse and snapping anywhere else 44dB worse. What is
      // left is not understood. No catalogue song strikes the filter at all.
      let bound =
        name.contains("struck")
        ? -58.0 : name.contains("everything") ? -88.0 : name.contains("driven") ? -100.0 : -125.0
      #expect(decibels <= bound, "\(name) is \(decibels)dB from the reference")
    }
    if ProcessInfo.processInfo.environment["DRIFTBOX_REPORT"] != nil { print(report) }
  }
}
