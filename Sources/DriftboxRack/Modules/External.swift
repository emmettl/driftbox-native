// A processor the rack does not own: a plug-in, rendered by the host. Native only — the reference
// has nothing like it, and keeps a patch's `plugin` module as a placeholder.
//
// The graph knows only a C function and a context to call it with, both put in the module's slot
// by the host, so nothing about any plug-in format reaches the constrained targets. Until the host
// fills the slot, or when the plug-in is missing, the module is silent, as a placeholder is.

/// One block of an external processor: its `context`; the module's inlet buffers and its outlet
/// buffers, one per slot as `Slots` has them, never to write to the first nor leave any of the
/// second unwritten; the block's frames; and where the transport is, for a plug-in keeping time.
public typealias ExternalRender =
  @convention(c) (
    _ context: UnsafeMutableRawPointer?,
    _ inlets: UnsafePointer<UnsafeMutablePointer<Float>>,
    _ outlets: UnsafePointer<UnsafeMutablePointer<Float>>,
    _ frames: Int, _ tempo: Double, _ beat: Double, _ running: Bool
  ) -> Void

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
    guard let render = current.render else {
      for outlet in 0..<outlets.count { outlets[outlet].update(repeating: 0, count: context.frames) }
      return
    }
    let transport = context.transport
    // The one call on the render path the checker cannot see into: what it reaches is the host's,
    // which answers for it being as careful as everything here.
    _unsafePerformance {
      render(
        current.context, UnsafePointer(inlets.base), UnsafePointer(outlets.base), context.frames,
        transport.tempo, transport.beat, transport.running)
    }
  }

  func release() { slot.deallocate() }
}

extension RackModules {
  /// Types this build has that the reference does not.
  public static let nativeOnly: Set<String> = ["plugin"]

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
