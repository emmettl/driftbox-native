import DriftboxRack
import Synchronization

/// What the interface asks of the rack's render thread.
public enum RackCommand {
  /// Play this graph from now on. The one it replaces goes back through the release ring.
  case load(UnsafeMutablePointer<RackGraph>?)
  /// A knob, on every voice (`voice` -1) or one, now (`frame` -1) or at a frame of the graph's clock.
  case param(slot: Int, value: Double, voice: Int, frame: Int)
  case transport(tempo: Double, running: Bool, shuffle: Double)
}

/// A single-producer, single-consumer ring of rack commands, as `CommandRing` is for the engine.
public struct RackCommandRing: ~Copyable {
  public static var capacity: Int { 256 }
  let slots: UnsafeMutablePointer<RackCommand>
  let head = Atomic<Int>(0)
  let tail = Atomic<Int>(0)

  public init() {
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: .load(nil), count: Self.capacity)
  }

  deinit { slots.deallocate() }

  @discardableResult
  public func send(_ command: RackCommand) -> Bool {
    let write = tail.load(ordering: .relaxed)
    let read = head.load(ordering: .acquiring)
    if write - read >= Self.capacity { return false }
    slots[write % Self.capacity] = command
    tail.store(write + 1, ordering: .releasing)
    return true
  }

  @_noAllocation
  public func receive() -> RackCommand? {
    let read = head.load(ordering: .relaxed)
    let write = tail.load(ordering: .acquiring)
    if read == write { return nil }
    let command = slots[read % Self.capacity]
    head.store(read + 1, ordering: .releasing)
    return command
  }
}

/// Graphs the render thread has finished with, for the interface to free.
public struct RackReleaseRing: ~Copyable {
  public static var capacity: Int { 16 }
  let slots: UnsafeMutablePointer<UnsafeMutablePointer<RackGraph>?>
  let head = Atomic<Int>(0)
  let tail = Atomic<Int>(0)

  public init() {
    slots = .allocate(capacity: Self.capacity)
    slots.initialize(repeating: nil, count: Self.capacity)
  }

  deinit { slots.deallocate() }

  @_noAllocation
  public func send(_ graph: UnsafeMutablePointer<RackGraph>) {
    let write = tail.load(ordering: .relaxed)
    let read = head.load(ordering: .acquiring)
    // A full ring leaks the graph rather than freeing it on the render thread.
    if write - read >= Self.capacity { return }
    slots[write % Self.capacity] = graph
    tail.store(write + 1, ordering: .releasing)
  }

  public func receive() -> UnsafeMutablePointer<RackGraph>? {
    let read = head.load(ordering: .relaxed)
    let write = tail.load(ordering: .acquiring)
    if read == write { return nil }
    let graph = slots[read % Self.capacity]
    head.store(read + 1, ordering: .releasing)
    return graph
  }
}

/// The rack, for a render callback: patches compiled and built on the interface's thread and
/// swapped in whole, knobs and the transport through a ring, and the graph's fixed blocks cut to
/// whatever size the device asks for. The same division of labour as `EngineHost`.
public final class RackHost: @unchecked Sendable {
  public let sampleRate: Double
  public let blockFrames: Int
  let commands: UnsafeMutablePointer<RackCommandRing>
  let released: UnsafeMutablePointer<RackReleaseRing>
  /// The render thread's graph. Only the render thread reads or writes it.
  let current: UnsafeMutablePointer<UnsafeMutablePointer<RackGraph>?>
  /// One block of output, and how much of it has been handed out.
  let blockLeft: UnsafeMutablePointer<Float>
  let blockRight: UnsafeMutablePointer<Float>
  let blockUsed: UnsafeMutablePointer<Int>
  /// Graphs made and not yet freed, so the host can free them all when it goes.
  private var owned: [UnsafeMutablePointer<RackGraph>] = []
  private let lock = Mutex<Void>(())

  /// The plan the interface last loaded: what a knob's name is looked up in.
  public private(set) var plan: Plan?
  /// The graph's clock, as the render thread last left it: what a scheduled knob is placed against.
  public let frame = Atomic<Int>(0)

  /// The graph the render thread is playing, by address, for readings to be taken from. It stays
  /// alive while it is read, because it is freed only by `collect`, on the same thread as reads.
  let playing = Atomic<Int>(0)
  /// Counts snapshots of the meters, and is odd while one is being written: a reader that sees it
  /// change, or odd, reads again.
  let meterSequence = Atomic<Int>(0)
  /// Blocks since the last snapshot. Only the render thread touches it.
  let sinceMeters: UnsafeMutablePointer<Int>
  /// How often the meters are copied: every eight blocks, as the reference's worklet posts them.
  public static var meterEvery: Int { 8 }
  /// The last readings that were whole, for when a read keeps losing to the render thread.
  private var lastReadings: [String: MeterReading] = [:]

  public init(sampleRate: Double, blockFrames: Int = 128) {
    self.sampleRate = sampleRate
    self.blockFrames = blockFrames
    commands = .allocate(capacity: 1)
    commands.initialize(to: RackCommandRing())
    released = .allocate(capacity: 1)
    released.initialize(to: RackReleaseRing())
    current = .allocate(capacity: 1)
    current.initialize(to: nil)
    blockLeft = .allocate(capacity: blockFrames)
    blockLeft.initialize(repeating: 0, count: blockFrames)
    blockRight = .allocate(capacity: blockFrames)
    blockRight.initialize(repeating: 0, count: blockFrames)
    blockUsed = .allocate(capacity: 1)
    blockUsed.initialize(to: blockFrames)
    sinceMeters = .allocate(capacity: 1)
    sinceMeters.initialize(to: 0)
  }

  deinit {
    for graph in owned {
      graph.deinitialize(count: 1)
      graph.deallocate()
    }
    commands.deinitialize(count: 1)
    commands.deallocate()
    released.deinitialize(count: 1)
    released.deallocate()
    current.deallocate()
    blockLeft.deallocate()
    blockRight.deallocate()
    blockUsed.deallocate()
    sinceMeters.deallocate()
  }

  // MARK: - From the interface

  /// Compile and build `patch` here, and have the render thread play it from its next call.
  public func load(_ patch: Patch) {
    collect()
    let compiled = compile(patch)
    plan = compiled
    let graph = UnsafeMutablePointer<RackGraph>.allocate(capacity: 1)
    graph.initialize(to: RackGraph(plan: compiled, sampleRate: sampleRate, frames: blockFrames))
    lock.withLock { _ in owned.append(graph) }
    commands.pointee.send(.load(graph))
  }

  /// Turn a knob by module and param id: now, or at `frame` of the graph's clock.
  public func setParam(
    _ module: String, _ param: String, _ value: Double, voice: Int? = nil, frame: Int? = nil
  ) {
    guard let slot = plan?.slots[module]?[param] else { return }
    commands.pointee.send(.param(slot: slot, value: value, voice: voice ?? -1, frame: frame ?? -1))
  }

  public func setTransport(tempo: Double, running: Bool, shuffle: Double = 0) {
    commands.pointee.send(.transport(tempo: tempo, running: running, shuffle: shuffle))
  }

  /// What the metered modules are showing, by module id, as of the render thread's last copy of
  /// them: for the interface, on its own thread, several times a second.
  public func readings() -> [String: MeterReading] {
    let address = playing.load(ordering: .acquiring)
    guard let graph = UnsafeMutablePointer<RackGraph>(bitPattern: address) else { return [:] }
    for _ in 0..<8 {
      let before = meterSequence.load(ordering: .acquiring)
      if before & 1 == 1 { continue }
      let taken = graph.pointee.meterReadings()
      atomicMemoryFence(ordering: .acquiring)
      guard meterSequence.load(ordering: .relaxed) == before else { continue }
      lastReadings = Dictionary(taken.map { ($0.id, $0.reading) }, uniquingKeysWith: { a, _ in a })
      return lastReadings
    }
    return lastReadings
  }

  /// Free the graphs the render thread has let go of.
  public func collect() {
    while let graph = released.pointee.receive() {
      lock.withLock { _ in owned.removeAll { $0 == graph } }
      graph.deinitialize(count: 1)
      graph.deallocate()
    }
  }

  // MARK: - From the render thread

  /// `frames` frames into `left` and `right`, whatever size the device asks for.
  @_noAllocation
  public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
    while let command = commands.pointee.receive() {
      switch command {
      case .load(let graph):
        if let graph, let previous = current.pointee {
          // The clock, the transport and the limiter carry on; the modules start again.
          graph.pointee.inherit(previous.pointee.carried)
        }
        if let previous = current.pointee { released.pointee.send(previous) }
        current.pointee = graph
        playing.store(Int(bitPattern: graph), ordering: .releasing)
      case .param(let slot, let value, let voice, let frame):
        current.pointee?.pointee.setParam(
          slot: slot, value: value, voice: voice < 0 ? nil : voice, frame: frame < 0 ? nil : frame)
      case .transport(let tempo, let running, let shuffle):
        current.pointee?.pointee.setTransport(tempo: tempo, running: running, shuffle: shuffle)
      }
    }
    var done = 0
    while done < frames {
      if blockUsed.pointee >= blockFrames {
        if let graph = current.pointee {
          graph.pointee.process(left: blockLeft, right: blockRight)
          frame.store(graph.pointee.frame, ordering: .relaxed)
          sinceMeters.pointee += 1
          if sinceMeters.pointee >= 8 {  // `meterEvery`
            sinceMeters.pointee = 0
            meterSequence.wrappingAdd(1, ordering: .acquiringAndReleasing)
            graph.pointee.snapshotMeters()
            meterSequence.wrappingAdd(1, ordering: .releasing)
          }
        } else {
          for i in 0..<blockFrames {
            blockLeft[i] = 0
            blockRight[i] = 0
          }
        }
        blockUsed.pointee = 0
      }
      let take = min(blockFrames - blockUsed.pointee, frames - done)
      for i in 0..<take {
        left[done + i] = blockLeft[blockUsed.pointee + i]
        right[done + i] = blockRight[blockUsed.pointee + i]
      }
      blockUsed.pointee += take
      done += take
    }
  }
}
