import DriftboxDSP
import DriftboxRack
import Foundation
import Testing

/// The groovebox's four meters, which the reference's render fixtures do not carry: each machine
/// read after its strip, under `<id>:<machine>`, held to the reference's `meters()` arithmetic
/// worked again here from what went in.
struct GrooveboxModuleTests {
  @Test func eachMachineIsMeteredAfterItsStrip() throws {
    let patch = Patch(
      modules: [
        PatchModule(
          id: "song", type: "groovebox",
          params: [
            "tr808-level": 0.8, "tr808-pan": -0.6, "tr909-mute": 1, "303-a-pan": 0.5, "303-b-level": 0.25,
          ])
      ],
      cables: [])
    var graph = RackGraph(plan: compile(patch), sampleRate: 48000)
    let host = HostBuses(count: 4)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    // Level, pan and mute for each machine, as the patch sets them.
    let strips: [(level: Double, pan: Double, muted: Bool)] = [
      (0.8, -0.6, false), (1, 0, true), (1, 0.5, false), (0.25, 0, false),
    ]
    var envelopes = [Float](repeating: 0, count: 4)
    for block in 0..<3 {
      host.fill(block: block)
      graph.process(left: left, right: right, host: host.inputs)
      let readings = Dictionary(uniqueKeysWithValues: graph.meters().map { ($0.id, $0.reading) })
      #expect(Set(readings.keys) == ["song:tr808", "song:tr909", "song:303.a", "song:303.b"])

      for (section, name) in GrooveboxModule.sections.enumerated() {
        let strip = strips[section]
        // A knob reaches a module as a float, as the reference's `Float32Array` params do.
        let level = Double(Float(strip.level))
        let pan = Double(Float(strip.pan))
        let gain = strip.muted ? 0 : level
        let leftGain = pan > 0 ? 1 - pan : 1
        let rightGain = pan < 0 ? 1 + pan : 1
        var outLeft = [Float](repeating: 0, count: 128)
        var outRight = [Float](repeating: 0, count: 128)
        var squares = 0.0
        var peak = 0.0
        for i in 0..<128 {
          outLeft[i] = Float(Double(host.pointers[section * 2][i]) * gain * leftGain)
          outRight[i] = Float(Double(host.pointers[section * 2 + 1][i]) * gain * rightGain)
          squares += Double(outLeft[i]) * Double(outLeft[i]) + Double(outRight[i]) * Double(outRight[i])
          peak = max(peak, abs(Double(outLeft[i])), abs(Double(outRight[i])))
        }
        let previous = Double(envelopes[section])
        let release = pow(0.01, 128 / (48000 * 0.3))
        envelopes[section] = Float(peak >= previous ? peak : peak + (previous - peak) * release)
        let waveform = (0..<48).map { point -> Float in
          let index = point * 128 / 48
          return Float(max(-1, min(1, (Double(outLeft[index]) + Double(outRight[index])) * 0.5)))
        }

        let reading = try #require(readings["song:\(name)"])
        #expect(reading.level == Double(Float((squares / 256).squareRoot())), "\(name) level, block \(block)")
        #expect(reading.peak == Double(Float(peak)), "\(name) peak, block \(block)")
        #expect(reading.envelope == Double(envelopes[section]), "\(name) envelope, block \(block)")
        #expect(reading.waveform == waveform, "\(name) waveform, block \(block)")
        #expect((reading.level == 0) == strip.muted, "\(name) is silent only when muted")
      }
    }
  }

  @Test func theMachinesAreTheReferencesSections() {
    #expect(GrooveboxModule.sections == ["tr808", "tr909", "303.a", "303.b"])
  }
}
