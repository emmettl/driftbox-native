import DriftboxDSP

// A processor the rack does not own: a plug-in, rendered by the host. Native only — the reference
// has nothing like it, and keeps a patch's `plugin` module as a placeholder.
//
// The graph knows only a C function and a context to call it with, both put in the module's slot
// by the host, so nothing about any plug-in format reaches the constrained targets. Until the host
// fills the slot, or when the plug-in is missing, the module is silent, as a placeholder is.

/// One block of an external processor: its `context`; the module's inlet buffers and its outlet
/// buffers, one per slot as `Slots` has them, never to write to the first nor leave any of the
/// second unwritten; the block's frames; where the transport is, for a plug-in keeping time; and
/// the MIDI the block plays, as `MIDIEvent` packs it, in order of frame.
public typealias ExternalRender =
  @convention(c) (
    _ context: UnsafeMutableRawPointer?,
    _ inlets: UnsafePointer<UnsafeMutablePointer<Float>>,
    _ outlets: UnsafePointer<UnsafeMutablePointer<Float>>,
    _ frames: Int, _ tempo: Double, _ beat: Double, _ running: Bool,
    _ events: UnsafePointer<UInt64>?, _ eventCount: Int
  ) -> Void

/// A three-byte MIDI message at a frame of the block, packed into one word so a block's worth is a
/// plain array a C function can take: the frame above, the status and two data bytes below.
public enum MIDIEvent {
  @_noAllocation
  public static func pack(frame: Int, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt64 {
    UInt64(truncatingIfNeeded: frame) << 32 | UInt64(status) << 16 | UInt64(data1) << 8 | UInt64(data2)
  }

  @_noAllocation
  public static func frame(_ event: UInt64) -> Int { Int(truncatingIfNeeded: event >> 32) }

  @_noAllocation
  public static func bytes(_ event: UInt64) -> (UInt8, UInt8, UInt8) {
    (
      UInt8(truncatingIfNeeded: event >> 16), UInt8(truncatingIfNeeded: event >> 8),
      UInt8(truncatingIfNeeded: event)
    )
  }
}

/// What a module's external slot holds: how to render, and with what. Empty is silence.
public struct ExternalSlot {
  public var render: ExternalRender?
  public var context: UnsafeMutableRawPointer?

  @_noAllocation
  public init(render: ExternalRender?, context: UnsafeMutableRawPointer?) {
    self.render = render
    self.context = context
  }

  public static var empty: ExternalSlot {
    @_noAllocation get { ExternalSlot(render: nil, context: nil) }
  }
}

/// The `plugin` module running: whatever the host has put in its slot.
public struct ExternalProcessor {
  /// Held apart from the processor, which is copied in and out of its case every block, so the
  /// host has one fixed place to swap a plug-in into.
  let slot: UnsafeMutablePointer<ExternalSlot>

  init() {
    slot = .allocate(capacity: 1)
    slot.initialize(to: .empty)
  }

  @_noAllocation
  func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let current = slot.pointee
    guard let render = current.render else { return silence(outlets, context.frames) }
    call(render, current.context, inlets, outlets, context, events: nil, count: 0)
  }

  @_noAllocation
  func call(
    _ render: ExternalRender, _ external: UnsafeMutableRawPointer?, _ inlets: Slots, _ outlets: Slots,
    _ context: ProcessContext, events: UnsafePointer<UInt64>?, count: Int
  ) {
    let transport = context.transport
    // The one call on the render path the checker cannot see into: what it reaches is the host's,
    // which answers for it being as careful as everything here.
    _unsafePerformance {
      render(
        external, UnsafePointer(inlets.base), UnsafePointer(outlets.base), context.frames, transport.tempo,
        transport.beat, transport.running, events, count)
    }
  }

  /// Silence on every outlet, for a slot with nothing in it.
  @_noAllocation
  func silence(_ outlets: Slots, _ frames: Int) {
    for outlet in 0..<outlets.count { outlets[outlet].update(repeating: 0, count: frames) }
  }

  func release() { slot.deallocate() }
}

/// The `plugin-instrument` module running: the rack's notes, every voice of them, made into MIDI
/// for the plug-in in its slot. A voice's gate going high is a note on, at the note its pitch is
/// nearest — 0 V is MIDI 36, as the MIDI module has it — and at its velocity; the gate falling, or
/// the pitch moving to another note while it is high, ends it. Mod, bend and sustain follow their
/// inlets, block by block. A new instance first lets go of every note a previous one left sounding,
/// since an edit that rebuilds the graph must not leave the plug-in holding one for ever.
public struct InstrumentProcessor {
  let external = ExternalProcessor()
  static let capacity = 512
  static let voiceLimit = 32
  let events: UnsafeMutablePointer<UInt64>
  /// Each voice's sounding note, or -1.
  let notes: UnsafeMutablePointer<Int>
  var started = false
  /// Events written this block.
  var count = 0
  /// What was last sent for mod, bend and sustain, or -1 for nothing yet.
  var mod = -1
  var bend = -1
  var sustain = -1

  init() {
    events = .allocate(capacity: Self.capacity)
    events.initialize(repeating: 0, count: Self.capacity)
    notes = .allocate(capacity: Self.voiceLimit)
    notes.initialize(repeating: -1, count: Self.voiceLimit)
  }

  /// The inlets, in the def's order.
  static let pitch = 0
  static let gate = 1
  static let velocity = 2
  static let modInlet = 3
  static let bendInlet = 4
  static let sustainInlet = 5

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    count = 0
    if !started {
      started = true
      push(0, 0xB0, 123, 0)
    }

    // Mod, bend and sustain: once a block, when they change.
    let modNow = Int(jsRound(max(0, min(1, Double(inlets[Self.modInlet][0]))) * 127))
    if modNow != mod {
      mod = modNow
      push(0, 0xB0, 1, UInt8(modNow))
    }
    let bendNow = Int(jsRound((max(-1, min(1, Double(inlets[Self.bendInlet][0]))) + 1) * 8191.5))
    let bendClamped = max(0, min(16383, bendNow))
    if bendClamped != bend {
      bend = bendClamped
      push(0, 0xE0, UInt8(bendClamped & 0x7F), UInt8(bendClamped >> 7))
    }
    let sustainNow = inlets[Self.sustainInlet][0] >= 0.5 ? 127 : 0
    if sustainNow != sustain {
      sustain = sustainNow
      push(0, 0xB0, 64, UInt8(sustainNow))
    }

    // Notes, voice by voice, sample by sample.
    let gates = context.voiceInlets?[Self.gate]
    let pitches = context.voiceInlets?[Self.pitch]
    let velocities = context.voiceInlets?[Self.velocity]
    let voices = min(Self.voiceLimit, max(1, gates?.count ?? 1))
    let velocityPatched = context.inletConnected[Self.velocity]
    for i in 0..<frames {
      for voice in 0..<voices {
        let gate = gates.map { $0[min(voice, $0.count - 1)][i] } ?? inlets[Self.gate][i]
        let sounding = notes[voice]
        guard gate >= 0.5 else {
          if sounding >= 0 {
            push(i, 0x80, UInt8(sounding), 0)
            notes[voice] = -1
          }
          continue
        }
        let pitch = pitches.map { $0[min(voice, $0.count - 1)][i] } ?? inlets[Self.pitch][i]
        let exact = Double(pitch) * 12 + 36
        let note = exact.isFinite ? Int(max(0, min(127, jsRound(exact)))) : 60
        if sounding == note { continue }
        if sounding >= 0 { push(i, 0x80, UInt8(sounding), 0) }
        // Unpatched, the MIDI module's own default of 0.8.
        let raw =
          velocityPatched
          ? velocities.map { $0[min(voice, $0.count - 1)][i] } ?? inlets[Self.velocity][i] : 0.8
        let level = Double(raw)
        let velocity = level.isFinite ? Int(max(1, min(127, jsRound(level * 127)))) : 100
        push(i, 0x90, UInt8(note), UInt8(velocity))
        notes[voice] = note
      }
    }

    let current = external.slot.pointee
    guard let render = current.render else { return external.silence(outlets, frames) }
    external.call(
      render, current.context, inlets, outlets, context, events: UnsafePointer(events), count: count)
  }

  @_noAllocation
  mutating func push(_ frame: Int, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
    guard count < Self.capacity else { return }
    events[count] = MIDIEvent.pack(frame: frame, status, data1, data2)
    count += 1
  }

  func release() {
    external.release()
    events.deallocate()
    notes.deallocate()
  }
}

extension RackModules {
  /// The modules that host a plug-in, and so carry a `plugin` in the patch.
  public static let pluginTypes: Set<String> = ["plugin", "plugin-instrument"]

  /// Types this build has that the reference does not.
  public static let nativeOnly: Set<String> = pluginTypes

  /// An instrument: a plug-in played by the rack's notes, every voice of them, onto a stereo
  /// outlet. Pitch, gate and velocity as the MIDI module gives them, and its mod, bend and sustain.
  static let pluginInstrument: ModuleDef = {
    var def = ModuleDef(
      type: "plugin-instrument", name: "Plug-in Instrument",
      inlets: [
        Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity"), Port("mod", "Mod"),
        Port("bend", "Pitch Bend"), Port("sustain", "Sustain"),
      ],
      outlets: [Port("out", "Out", stereo: true)], params: [])
    // One instance, reading every voice: the plug-in does its own voicing.
    def.poly = false
    def.voiceCollector = true
    return def
  }()

  /// A stereo effect: a plug-in between a stereo inlet and a stereo outlet. What it is, and its
  /// state, are the module's `plugin` in the patch, not its params, which it has none of.
  static let plugin: ModuleDef = {
    var def = ModuleDef(
      type: "plugin", name: "Plug-in", inlets: [Port("in", "In", stereo: true)],
      outlets: [Port("out", "Out", stereo: true)], params: [])
    // One instance, however many voices: a plug-in is one thing with one state.
    def.poly = false
    return def
  }()
}
