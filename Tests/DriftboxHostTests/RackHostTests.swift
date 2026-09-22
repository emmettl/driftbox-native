import DriftboxHost
import DriftboxRack
import Testing

/// The rack's real-time host against its headless renderer: the same patch, the same sound,
/// whatever size of block the device asks for.
struct RackHostTests {
  static let patch = Patch(
    modules: [
      PatchModule(id: "osc", type: "vco", params: ["tune": -12]),
      PatchModule(id: "sweep", type: "lfo", params: ["rate": 3]),
      PatchModule(id: "filter", type: "ladder", params: ["cutoff": 900, "resonance": 0.7]),
      PatchModule(id: "out", type: "out"),
    ],
    cables: [
      PatchCable(from: PortReference("osc", "out"), to: PortReference("filter", "in")),
      PatchCable(from: PortReference("sweep", "bi"), to: PortReference("filter", "cutoff")),
      PatchCable(from: PortReference("filter", "out"), to: PortReference("out", "in")),
    ])

  func render(_ host: RackHost, frames: Int, callback: Int) -> [Float] {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    var done = 0
    while done < frames {
      let count = min(callback, frames - done)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          host.render(frames: count, left: l.baseAddress! + done, right: r.baseAddress! + done)
        }
      }
      done += count
    }
    return left
  }

  @Test(arguments: [128, 333, 37, 1024])
  func soundsAsTheRendererDoes(callback: Int) {
    let host = RackHost(sampleRate: 48000)
    host.load(Self.patch)
    let renderer = RackRenderer(sampleRate: 48000)
    renderer.patch = Self.patch
    let mine = render(host, frames: 9600, callback: callback)
    #expect(mine == renderer.render(frames: 9600).left)
    #expect(mine.contains { $0 != 0 })
  }

  @Test func knobsAndTheTransportGoThroughTheRing() {
    let host = RackHost(sampleRate: 48000)
    host.load(Self.patch)
    _ = render(host, frames: 1024, callback: 256)
    host.setParam("out", "level", 0)
    host.setParam("nobody", "level", 1)
    _ = render(host, frames: 256, callback: 256)
    #expect(render(host, frames: 1024, callback: 256).allSatisfy { $0 == 0 })
  }

  /// A new patch restarts the modules and keeps the clock: a knob scheduled against the old
  /// graph's frames still means the same moment.
  @Test func aNewPatchKeepsTheClock() {
    let host = RackHost(sampleRate: 48000)
    host.load(Self.patch)
    _ = render(host, frames: 1280, callback: 128)
    #expect(host.frame.load(ordering: .relaxed) == 1280)
    host.load(Self.patch)
    _ = render(host, frames: 128, callback: 128)
    #expect(host.frame.load(ordering: .relaxed) == 1408)
    host.collect()
  }
}
