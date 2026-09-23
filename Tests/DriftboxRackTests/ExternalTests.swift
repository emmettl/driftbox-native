import DriftboxDocument
import DriftboxRack
import Foundation
import Testing

/// The `plugin` module from the graph's side: whatever a host puts in its slot runs in the
/// module's place, between its inlets and its outlets, and an empty slot is silence.
struct ExternalTests {
  /// Half of each inlet onto its outlet, and the transport it was given kept at `context`.
  static let halve: ExternalRender = { context, inlets, outlets, frames, tempo, beat, running in
    for channel in 0..<2 {
      for i in 0..<frames { outlets[channel][i] = inlets[channel][i] * 0.5 }
    }
    if let context {
      let seen = context.assumingMemoryBound(to: (tempo: Double, beat: Double, running: Bool).self)
      seen.pointee = (tempo, beat, running)
    }
  }

  static func patch(through middle: PatchModule) -> Patch {
    Patch(
      modules: [
        PatchModule(id: "osc", type: "vco", params: ["tune": 3]), middle, PatchModule(id: "out", type: "out"),
      ],
      cables: [
        PatchCable(from: PortReference("osc", "out"), to: PortReference(middle.id, "in")),
        PatchCable(from: PortReference(middle.id, "out"), to: PortReference("out", "in")),
      ])
  }

  static func render(_ graph: inout RackGraph, blocks: Int = 40) -> [Float] {
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    defer {
      left.deallocate()
      right.deallocate()
    }
    var out: [Float] = []
    for _ in 0..<blocks {
      graph.process(left: left, right: right)
      out += UnsafeBufferPointer(start: left, count: 128)
      out += UnsafeBufferPointer(start: right, count: 128)
    }
    return out
  }

  /// A processor in the slot is heard exactly where the module is: halving is a VCA at a half.
  @Test func whatTheHostPutsInTheSlotRunsInTheModulesPlace() throws {
    var hosted = RackGraph(
      plan: compile(Self.patch(through: PatchModule(id: "fx", type: "plugin"))), sampleRate: 48000)
    #expect(hosted.missing.isEmpty)
    let seen = UnsafeMutablePointer<(tempo: Double, beat: Double, running: Bool)>.allocate(capacity: 1)
    seen.initialize(to: (0, 0, false))
    defer { seen.deallocate() }
    let found = hosted.externalEntry(module: "fx")
    let entry = try #require(found)
    entry.pointee = ExternalSlot(render: Self.halve, context: UnsafeMutableRawPointer(seen))
    hosted.setTransport(tempo: 97, running: true)
    let through = Self.render(&hosted)

    var reference = RackGraph(
      plan: compile(Self.patch(through: PatchModule(id: "fx", type: "vca", params: ["gain": 0.5]))),
      sampleRate: 48000)
    reference.setTransport(tempo: 97, running: true)
    let expected = Self.render(&reference)
    #expect(through == expected)
    #expect(through.contains { $0 != 0 })
    #expect(seen.pointee.tempo == 97)
    #expect(seen.pointee.running)
    #expect(seen.pointee.beat > 0, "the transport as it stands at each block")
  }

  /// Nothing in the slot — no host, or a plug-in this machine does not have — and it is silent,
  /// as a placeholder is.
  @Test func anEmptySlotIsSilence() {
    var graph = RackGraph(
      plan: compile(Self.patch(through: PatchModule(id: "fx", type: "plugin"))), sampleRate: 48000)
    #expect(Self.render(&graph).allSatisfy { $0 == 0 })
  }

  @Test func onlyAPluginModuleHasASlot() {
    let graph = RackGraph(
      plan: compile(Self.patch(through: PatchModule(id: "fx", type: "plugin"))), sampleRate: 48000)
    let slots = ["fx", "osc", "nothing"].map { graph.externalEntry(module: $0) != nil }
    #expect(slots == [true, false, false])
  }

  /// The patch keeps the plug-in whole — which, and its state — and a module with none is written
  /// as it always was.
  @Test func thePatchKeepsThePlugin() throws {
    var module = PatchModule(id: "fx", type: "plugin")
    module.plugin = PluginReference(
      format: "audio-unit", id: "aufx dely appl", name: "AUDelay", vendor: "Apple", state: "YnBsaXN0MDA=")
    let patch = Self.patch(through: module)
    let text = PatchCodec.encode(patch)
    #expect(
      text.contains(
        #""plugin":{"format":"audio-unit","id":"aufx dely appl","name":"AUDelay","vendor":"Apple","state":"YnBsaXN0MDA="}"#
      ))
    let back = try #require(PatchCodec.decode(text))
    #expect(back == patch)
    #expect(PatchCodec.encode(back) == text)

    let plain = Self.patch(through: PatchModule(id: "fx", type: "vca"))
    #expect(!PatchCodec.encode(plain).contains("plugin"))

    // One the reader cannot say what it is, it leaves off: the module stays, silent.
    let damaged = text.replacingOccurrences(of: #""format":"audio-unit","#, with: "")
    let read = try #require(PatchCodec.decode(damaged))
    #expect(read.modules[1].plugin == nil)
    #expect(read.modules[1].type == "plugin")
  }
}
