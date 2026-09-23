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
  /// What the faceplates read: copied off the render thread every eight blocks, and the same as
  /// the modules themselves report when asked directly after the same blocks.
  @Test func theMetersAreReadAsTheModulesThemselvesShowThem() throws {
    let patch = Patch(
      modules: [
        PatchModule(id: "osc", type: "vco", params: ["shape": 2]),
        PatchModule(id: "tune", type: "tuner"),
        PatchModule(id: "vu", type: "meter"),
        PatchModule(id: "loop", type: "looper", params: ["mode": 1]),
        PatchModule(id: "out", type: "out"),
      ],
      cables: [
        PatchCable(from: PortReference("osc", "out"), to: PortReference("tune", "in")),
        PatchCable(from: PortReference("tune", "thru"), to: PortReference("vu", "in")),
        PatchCable(from: PortReference("vu", "thru"), to: PortReference("loop", "in")),
        PatchCable(from: PortReference("loop", "out"), to: PortReference("out", "in")),
      ])
    let host = RackHost(sampleRate: 48000)
    #expect(host.readings().isEmpty)
    host.load(patch)
    // Forty blocks, in callbacks of an awkward size: five snapshots.
    _ = render(host, frames: 40 * 128, callback: 333)
    let readings = host.readings()
    #expect(Set(readings.keys) == ["tune", "vu", "loop"])

    var graph = RackGraph(plan: compile(patch), sampleRate: 48000)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    for _ in 0..<40 { graph.process(left: left, right: right) }
    for (id, direct) in graph.meters() {
      let live = try #require(readings[id])
      #expect(live.level == direct.level, "\(id)")
      #expect(live.peak == direct.peak, "\(id)")
      #expect(live.envelope == direct.envelope, "\(id)")
      #expect(live.waveform == direct.waveform, "\(id)")
      #expect(live.frequency == direct.frequency, "\(id)")
      #expect(live.clarity == direct.clarity, "\(id)")
      #expect(live.loopPosition == direct.loopPosition, "\(id)")
      #expect(live.loopSeconds == direct.loopSeconds, "\(id)")
    }
    // And they say something: a triangle at C2 is 65.4Hz, and the looper has been recording.
    let tuned = try #require(readings["tune"]?.frequency)
    #expect(abs(tuned - 65.406) < 0.5, "\(tuned)")
    #expect((readings["vu"]?.level ?? 0) > 0.1)
    #expect((readings["loop"]?.loopSeconds ?? 0) > 0.09)
  }
}
