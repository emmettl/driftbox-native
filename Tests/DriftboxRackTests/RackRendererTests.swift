import DriftboxRack
import Testing

/// The renderer's own rules, beyond what the fixtures render.
struct RackRendererTests {
  static func patch(level: Double = 0.7) -> Patch {
    Patch(
      modules: [
        PatchModule(id: "osc", type: "vco"), PatchModule(id: "out", type: "out", params: ["level": level]),
      ],
      cables: [PatchCable(from: PortReference("osc", "out"), to: PortReference("out", "in"))])
  }

  @Test func noPatchIsSilence() {
    let renderer = RackRenderer()
    let (left, right) = renderer.render(frames: 300)
    #expect(left.count == 300 && right.count == 300)
    #expect(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
  }

  /// A render is whole blocks trimmed to the length asked for, and the next render carries on
  /// from where the graph's clock got to rather than starting again.
  @Test func rendersAreTrimmedAndTheClockMovesOn() {
    let renderer = RackRenderer()
    renderer.patch = Self.patch()
    let first = renderer.render(frames: 200)
    let second = renderer.render(frames: 200)
    #expect(first.left.count == 200)
    #expect(first.left != second.left)
  }

  /// A knob that does not exist is not an error: patches come from outside.
  @Test func anUnknownKnobIsIgnored() {
    let renderer = RackRenderer()
    renderer.patch = Self.patch()
    renderer.setParam("nobody", "level", 1)
    renderer.setParam("out", "nothing", 1)
    renderer.setParam("out", "level", .nan)
    let (left, _) = renderer.render(frames: 256)
    #expect(left.contains { $0 != 0 })
  }

  /// Mute on the only Out is silence; unmuted it comes back.
  @Test func muteAndSoloAreTheMastersBusiness() {
    let renderer = RackRenderer()
    renderer.patch = Self.patch()
    renderer.setParam("out", "mute", 1)
    _ = renderer.render(frames: 128)
    let muted = renderer.render(frames: 256)
    #expect(muted.left.allSatisfy { $0 == 0 })
    renderer.setParam("out", "mute", 0)
    _ = renderer.render(frames: 128)
    #expect(renderer.render(frames: 256).left.contains { $0 != 0 })
  }

  /// A feedback cable compiles, runs and says so.
  @Test func aCycleIsReportedAndRuns() {
    let renderer = RackRenderer()
    renderer.patch = Patch(
      modules: [
        PatchModule(id: "osc", type: "vco"), PatchModule(id: "filter", type: "svf"),
        PatchModule(id: "out", type: "out"),
      ],
      cables: [
        PatchCable(from: PortReference("osc", "out"), to: PortReference("filter", "in")),
        PatchCable(from: PortReference("filter", "lp"), to: PortReference("osc", "fm")),
        PatchCable(from: PortReference("filter", "lp"), to: PortReference("out", "in")),
      ])
    #expect(renderer.notes.map(\.kind) == ["delayed"])
    let (left, _) = renderer.render(frames: 4800)
    #expect(left.allSatisfy { $0.isFinite && abs($0) <= 1 })
  }
}
