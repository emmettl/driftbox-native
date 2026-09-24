import DriftboxDocument
import DriftboxRack
import Foundation
import Testing

/// The `plugin` module from the graph's side: whatever a host puts in its slot runs in the
/// module's place, between its inlets and its outlets, and an empty slot is silence.
struct ExternalTests {
  /// Half of each inlet onto its outlet, and the transport it was given kept at `context`.
  static let halve: ExternalRender = { context, inlets, outlets, frames, tempo, beat, running, _, _ in
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

  // MARK: - Instruments

  /// Every event a block brings, at its frame of the graph's clock, into `context`: a cursor, a
  /// count, then frame and message in pairs. The outlets silent.
  static let record: ExternalRender = { context, _, outlets, frames, _, _, _, events, count in
    outlets[0].update(repeating: 0, count: frames)
    outlets[1].update(repeating: 0, count: frames)
    guard let log = context?.assumingMemoryBound(to: Int.self) else { return }
    for index in 0..<count {
      guard let event = events?[index] else { continue }
      let at = log[1]
      log[2 + 2 * at] = log[0] + MIDIEvent.frame(event)
      let (status, data1, data2) = MIDIEvent.bytes(event)
      log[3 + 2 * at] = Int(status) << 16 | Int(data1) << 8 | Int(data2)
      log[1] = at + 1
    }
    log[0] += frames
  }

  /// Two voices of the MIDI module played into an instrument, as MIDI at the frames they happen.
  @Test func theRacksNotesReachAnInstrumentAsMIDI() throws {
    var patch = Patch(
      modules: [
        PatchModule(id: "keys", type: "midi"), PatchModule(id: "synth", type: "plugin-instrument"),
        PatchModule(id: "out", type: "out"),
      ],
      cables: [
        PatchCable(from: PortReference("keys", "pitch"), to: PortReference("synth", "pitch")),
        PatchCable(from: PortReference("keys", "gate"), to: PortReference("synth", "gate")),
        PatchCable(from: PortReference("keys", "vel"), to: PortReference("synth", "velocity")),
        PatchCable(from: PortReference("synth", "out"), to: PortReference("out", "in")),
      ])
    patch.voices = 2
    let plan = compile(patch)
    var graph = RackGraph(plan: plan, sampleRate: 48000)
    #expect(graph.missing.isEmpty)
    let log = UnsafeMutablePointer<Int>.allocate(capacity: 2 + 2 * 256)
    log.initialize(repeating: 0, count: 2 + 2 * 256)
    defer { log.deallocate() }
    let found = graph.externalEntry(module: "synth")
    let entry = try #require(found)
    entry.pointee = ExternalSlot(render: Self.record, context: UnsafeMutableRawPointer(log))

    let keys = try #require(plan.slots["keys"])
    let (note, gate, velocity) = try (
      #require(keys["note"]), #require(keys["gate"]), #require(keys["velocity"])
    )
    graph.setParam(slot: note, value: 48, voice: 0)
    graph.setParam(slot: note, value: 55, voice: 1)
    graph.setParam(slot: velocity, value: 0.5, voice: 0)
    // On block boundaries: a stepped param changed partway through a block keeps its old value at
    // the head of every block after, in the reference's graph as in this one.
    graph.setParam(slot: gate, value: 1, voice: 0, frame: 256)
    graph.setParam(slot: gate, value: 1, voice: 1, frame: 384)
    graph.setParam(slot: gate, value: 0, voice: 0, frame: 640)
    graph.setParam(slot: gate, value: 0, voice: 1, frame: 896)
    // Legato: the held voice's pitch glides up two semitones across a block, each note it passes
    // ending the one before.
    graph.setParam(slot: note, value: 57, voice: 1, frame: 512)
    _ = Self.render(&graph, blocks: 4)
    // What it has sounding, for its face: both voices, once both gates are up.
    let sounding = graph.meters().first { $0.id == "synth" }?.reading.notes
    #expect(sounding == [48, 55])
    _ = Self.render(&graph, blocks: 6)
    #expect(graph.meters().first { $0.id == "synth" }?.reading.notes == [])

    let events = (0..<log[1]).map { [log[2 + 2 * $0], log[3 + 2 * $0]] }
    #expect(
      events == [
        // A fresh instance lets go of anything left sounding, then says where mod, bend and sustain are.
        [0, 0xB0_7B00], [0, 0xB0_0100], [0, 0xE0_0040], [0, 0xB0_4000],
        [256, 0x90_3040], [384, 0x90_3766], [543, 0x80_3700], [543, 0x90_3866], [607, 0x80_3800],
        [607, 0x90_3966], [640, 0x80_3000], [896, 0x80_3900],
      ], "\(events.map { ($0[0], String($0[1], radix: 16)) })")
  }
}
