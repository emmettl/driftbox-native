import DriftboxEngine
import DriftboxRack
import DriftboxSeq
import Synchronization

/// What the interface asks of the rack's render thread.
public enum RackCommand {
  /// Play this graph from now on. The one it replaces goes back through the release ring.
  case load(UnsafeMutablePointer<RackGraph>?)
  /// A knob, on every voice (`voice` -1) or one, now (`frame` -1) or at a frame of the graph's clock.
  case param(slot: Int, value: Double, voice: Int, frame: Int)
  case transport(tempo: Double, running: Bool, shuffle: Double)
  /// Whether a song is hosted beside the rack, and which of its machines the rack takes: bit `n`
  /// for machine `n`, diverted from the song's mix to the rack's input buses alone.
  case hosting(Bool, diverted: UInt8)
  /// A module's data slot, swapped whole on a block boundary so a module never reads a new pointer
  /// with an old count. Ignored unless `graph` is the one playing.
  case data(
    graph: UnsafeMutablePointer<RackGraph>, entry: UnsafeMutablePointer<DataBuffer>, buffer: DataBuffer)
  /// A `plugin` module's processor, put in on a block boundary. Ignored unless `graph` is playing.
  case external(
    graph: UnsafeMutablePointer<RackGraph>, entry: UnsafeMutablePointer<ExternalSlot>, slot: ExternalSlot)
}

/// A processor from outside the rack for a `plugin` module to run — a plug-in — as the host is
/// given it: the render function and its context, and the object that keeps the context alive,
/// which the host holds for as long as any graph might call it.
public struct RackExternal {
  public var render: ExternalRender
  public var context: UnsafeMutableRawPointer
  public var owner: AnyObject

  public init(render: ExternalRender, context: UnsafeMutableRawPointer, owner: AnyObject) {
    self.render = render
    self.context = context
    self.owner = owner
  }
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
  /// The graph loaded last, which is the one new data is meant for.
  private var latest: UnsafeMutablePointer<RackGraph>?
  /// Data swapped into each graph since it was built, freed with it: a buffer replaced by a newer
  /// one may still be being read until the block ends, and the graph going is the moment it is
  /// certainly not.
  private var copies: [UnsafeMutablePointer<RackGraph>: [UnsafeMutablePointer<Float>]] = [:]
  /// Revisions for swapped data, far above any a graph numbers its own from.
  private var dataRevision = 1 << 40

  /// Audio a module plays that the patch does not carry — a sample loaded from a file, a break —
  /// by module and slot. Kept here so every graph built after it is loaded plays it too, without
  /// a copy: each graph's slot points at the one buffer, which lives while any graph does.
  private var samples: [String: [String: SampleBuffer]] = [:]
  /// The sample buffers and plug-ins each graph points at, released with it.
  private var retained: [UnsafeMutablePointer<RackGraph>: [AnyObject]] = [:]
  /// The processors `plugin` modules run, by module: like the samples, kept here so that every
  /// graph built after one arrives runs the same instance, its state intact through any edit.
  private var externals: [String: RackExternal] = [:]

  /// One sample's frames, owned, freed when the last graph pointing at it has gone.
  final class SampleBuffer {
    let frames: UnsafeMutablePointer<Float>
    let count: Int

    init(_ samples: [Float]) {
      count = samples.count
      frames = .allocate(capacity: max(1, count))
      samples.withUnsafeBufferPointer { source in
        if let base = source.baseAddress { frames.initialize(from: base, count: count) }
      }
    }

    deinit { frames.deallocate() }
  }
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

  /// The patch's retained groovebox song, played beside the rack as the reference's rack mode
  /// plays it: an engine of its own whose mix is added to the rack's, and whose four machines
  /// reach the rack on input buses 0 to 3 — the `groovebox` module's way in.
  public let song: EngineHost
  /// The same host for the render thread, which may not retain or release it: `song` keeps it.
  let songOnRenderThread: Unmanaged<EngineHost>
  /// Each machine's block, left then right, the input buses the graph reads.
  let buses: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  /// The song's own mix for a block.
  let songLeft: UnsafeMutablePointer<Float>
  let songRight: UnsafeMutablePointer<Float>
  /// Whether there is a song, and which machines the rack takes. Only the render thread touches it.
  let hosting: UnsafeMutablePointer<(on: Bool, diverted: UInt8)>
  /// Where an app's transport last said to be, until the next block. The render thread's alone.
  let located: UnsafeMutablePointer<(beat: Double, moving: Bool, pending: Bool)>
  /// Whether the song was last told to play, so starting the rack starts it from the top once.
  private var songRunning = false
  /// Which machines the loaded patch takes, sent again when a song arrives.
  private var diverted: UInt8 = 0
  private var hasSong = false
  /// The tempo of the song last given, which the place in the next one is worked out from.
  private var songBPM = 120.0
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
    song = EngineHost(sampleRate: sampleRate)
    songOnRenderThread = Unmanaged.passUnretained(song)
    buses = .allocate(capacity: 8)
    for index in 0..<8 {
      buses[index] = .allocate(capacity: blockFrames)
      buses[index].initialize(repeating: 0, count: blockFrames)
    }
    songLeft = .allocate(capacity: blockFrames)
    songLeft.initialize(repeating: 0, count: blockFrames)
    songRight = .allocate(capacity: blockFrames)
    songRight.initialize(repeating: 0, count: blockFrames)
    hosting = .allocate(capacity: 1)
    hosting.initialize(to: (false, 0))
    located = .allocate(capacity: 1)
    located.initialize(to: (0, false, false))
  }

  deinit {
    for graph in owned {
      graph.deinitialize(count: 1)
      graph.deallocate()
    }
    for pointers in copies.values { for pointer in pointers { pointer.deallocate() } }
    commands.deinitialize(count: 1)
    commands.deallocate()
    released.deinitialize(count: 1)
    released.deallocate()
    current.deallocate()
    blockLeft.deallocate()
    blockRight.deallocate()
    blockUsed.deallocate()
    sinceMeters.deallocate()
    for index in 0..<8 { buses[index].deallocate() }
    buses.deallocate()
    songLeft.deallocate()
    songRight.deallocate()
    hosting.deallocate()
    located.deallocate()
  }

  // MARK: - From the interface

  /// Compile and build `patch` here, and have the render thread play it from its next call.
  public func load(_ patch: Patch) {
    collect()
    // The machines this patch takes into the rack, which a cable more or fewer changes.
    let routed = GrooveboxModule.routed(patch)
    if routed != diverted {
      diverted = routed
      if hasSong { commands.pointee.send(.hosting(true, diverted: diverted)) }
    }
    let compiled = compile(patch)
    plan = compiled
    let graph = UnsafeMutablePointer<RackGraph>.allocate(capacity: 1)
    graph.initialize(to: RackGraph(plan: compiled, sampleRate: sampleRate, frames: blockFrames))
    lock.withLock { _ in owned.append(graph) }
    latest = graph
    // The samples this host holds, pointed at before the graph is handed over: nothing else can be
    // reading it yet.
    for (module, slots) in samples {
      for (slot, buffer) in slots {
        guard let entry = graph.pointee.dataEntry(module: module, slot: slot) else { continue }
        dataRevision += 1
        entry.pointee = DataBuffer(
          samples: UnsafePointer(buffer.frames), count: buffer.count, revision: dataRevision)
        retained[graph, default: []].append(buffer)
      }
    }
    for (module, external) in externals {
      guard let entry = graph.pointee.externalEntry(module: module) else { continue }
      entry.pointee = ExternalSlot(render: external.render, context: external.context)
      retained[graph, default: []].append(external.owner)
    }
    commands.pointee.send(.load(graph))
  }

  /// Give a `plugin` module its processor, or take it away (nil, and the module is silent): kept
  /// for every graph after this one, and put into the one playing on its next block. The one it
  /// replaces is let go of once no graph that might call it is left.
  public func setExternal(_ module: String, _ external: RackExternal?) {
    externals[module] = external
    guard let graph = latest, let entry = graph.pointee.externalEntry(module: module) else { return }
    if let external { retained[graph, default: []].append(external.owner) }
    commands.pointee.send(
      .external(
        graph: graph, entry: entry,
        slot: external.map { ExternalSlot(render: $0.render, context: $0.context) } ?? .empty))
  }

  /// The processors the host holds for `plugin` modules, by module.
  public var externalModules: [String] { Array(externals.keys) }

  /// Every processor the host holds let go of: for a different patch, whose modules may share ids.
  public func clearExternals() {
    for module in externals.keys { setExternal(module, nil) }
  }

  /// Give a module audio the patch does not carry, or take it away (nil): kept for every graph
  /// after this one, and swapped into the one playing on its next block.
  public func setSample(_ module: String, _ slot: String, _ frames: [Float]?) {
    let buffer = frames.map(SampleBuffer.init)
    samples[module, default: [:]][slot] = buffer
    if samples[module]?.isEmpty == true { samples[module] = nil }
    guard let graph = latest, let entry = graph.pointee.dataEntry(module: module, slot: slot) else { return }
    dataRevision += 1
    if let buffer { retained[graph, default: []].append(buffer) }
    commands.pointee.send(
      .data(
        graph: graph, entry: entry,
        buffer: DataBuffer(
          samples: buffer.map { UnsafePointer($0.frames) }, count: buffer?.count ?? 0, revision: dataRevision)
      ))
  }

  /// Every sample the host holds forgotten: for a different patch, whose modules may share ids.
  public func clearSamples() {
    for (module, slots) in samples { for slot in slots.keys { setSample(module, slot, nil) } }
  }

  /// Replace one of a module's data slots — a pattern, a song, a scale — on the next block, without
  /// rebuilding anything, so a sequence can be edited while it plays.
  public func setData(_ module: String, _ slot: String, _ values: [Double]) {
    guard let graph = latest, let entry = graph.pointee.dataEntry(module: module, slot: slot) else { return }
    let copy = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
    for (index, value) in values.enumerated() { (copy + index).initialize(to: Float(value)) }
    copies[graph, default: []].append(copy)
    dataRevision += 1
    commands.pointee.send(
      .data(
        graph: graph, entry: entry,
        buffer: DataBuffer(samples: UnsafePointer(copy), count: values.count, revision: dataRevision)))
  }

  /// Turn a knob by module and param id: now, or at `frame` of the graph's clock.
  public func setParam(
    _ module: String, _ param: String, _ value: Double, voice: Int? = nil, frame: Int? = nil
  ) {
    guard let slot = plan?.slots[module]?[param] else { return }
    commands.pointee.send(.param(slot: slot, value: value, voice: voice ?? -1, frame: frame ?? -1))
  }

  /// Turn an inlet's trim pot. Only a pot off unity with something patched to its inlet has a
  /// slot; turning one onto or off unity is a change to the plan, which a load makes.
  public func setTrim(_ module: String, _ inlet: String, _ value: Double) {
    guard let slot = plan?.inputTrims[module]?[inlet] else { return }
    commands.pointee.send(.param(slot: slot, value: value, voice: -1, frame: -1))
  }

  ///
  /// `located` says the rack is already running or stopped where it should be, put there on the
  /// render thread by an app it plays inside (`locate`): the song is where the app is, and starting
  /// does not send it back to its top.
  public func setTransport(tempo: Double, running: Bool, shuffle: Double = 0, located: Bool = false) {
    commands.pointee.send(.transport(tempo: tempo, running: running, shuffle: shuffle))
    if located { songRunning = running }
    // The song goes with the rack: from its top when the rack starts, as the rack's own clock
    // does, and stopped, to ring out, when it stops.
    if running != songRunning {
      songRunning = running
      if running {
        song.send(.seek(songFrame: 0))
        song.send(.play)
      } else {
        song.send(.stop)
      }
    }
  }

  /// Move the song to `frame` of its own, playing: a start at a bar, which the rack's transport
  /// must be running for, or the song would play against a clock nothing else follows.
  public func startSong(atFrame frame: Int) {
    guard hasSong else { return }
    song.send(.seek(songFrame: max(0, frame)))
    if songRunning { song.send(.play) }
  }

  /// Loop `bars` bars of the song from `startBar`; zero bars loops nothing.
  public func loopSong(startBar: Int, bars: Int) {
    song.send(.loop(startBar: max(0, startBar), bars: max(0, bars)))
  }

  /// Play `song` beside the rack, or none. A song replacing another carries on where the other
  /// was, as an edit to the song the rack is playing should; the first one waits for the rack.
  public func setSong(_ song: Song?) {
    guard let song else {
      if hasSong {
        hasSong = false
        commands.pointee.send(.hosting(false, diverted: 0))
        self.song.send(.stop)
        songRunning = false
      }
      return
    }
    // Where the song it replaces had got to, in its own tempo's frames.
    let position = max(0, self.song.songFrame.load(ordering: .relaxed))
    let replacing = hasSong
    self.song.load(song)
    if replacing {
      // The same beat of the new one, which a new tempo puts at another frame.
      let scaled = Int((Double(position) * songBPM / max(1, song.bpm)).rounded(.down))
      self.song.send(.seek(songFrame: scaled))
    } else {
      hasSong = true
      commands.pointee.send(.hosting(true, diverted: diverted))
      self.song.send(.seek(songFrame: 0))
    }
    songBPM = song.bpm
    if songRunning { self.song.send(.play) }
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
      for pointer in copies.removeValue(forKey: graph) ?? [] { pointer.deallocate() }
      retained[graph] = nil
    }
  }

  // MARK: - From the render thread

  /// Where an app the rack plays inside has its transport, at the start of a block: the clock at
  /// the app's beat, running or not as it is, and a song beside the rack at the same beat. Heard
  /// from the next of the rack's own blocks, which is at most one of them away.
  ///
  /// Done once whatever the interface sent before it has been taken: a patch it loaded is the one
  /// put at the beat.
  @_noAllocation
  public func locate(beat: Double, moving: Bool) {
    located.pointee = (beat, moving, true)
  }

  @_noAllocation
  private func takeLocate() {
    guard located.pointee.pending else { return }
    located.pointee.pending = false
    let (beat, moving, _) = located.pointee
    current.pointee?.pointee.locate(beat: beat, running: moving)
    if hosting.pointee.on {
      songOnRenderThread._withUnsafeGuaranteedRef { $0.locate(beat: beat, moving: moving) }
    }
  }

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
      case .data(let graph, let entry, let buffer):
        if current.pointee == graph { entry.pointee = buffer }
      case .external(let graph, let entry, let slot):
        if current.pointee == graph { entry.pointee = slot }
      case .hosting(let on, let diverted):
        hosting.pointee = (on, diverted)
      }
    }
    takeLocate()
    var done = 0
    while done < frames {
      if blockUsed.pointee >= blockFrames {
        // The song first, so its machines are on the buses the graph is about to read.
        let hosted = hosting.pointee.on
        if hosted {
          // Locals, so the closure holds pointers and not `self`, which it would retain.
          let sections = SectionOutputs(buffers: buses, diverted: hosting.pointee.diverted)
          let (frames, left, right) = (blockFrames, songLeft, songRight)
          songOnRenderThread._withUnsafeGuaranteedRef {
            $0.render(frames: frames, left: left, right: right, sections: sections)
          }
        }
        let inputs = hosted ? HostInputs(base: buses, buses: 4, channels: 2) : HostInputs.none
        if let graph = current.pointee {
          graph.pointee.process(left: blockLeft, right: blockRight, host: inputs)
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
        if hosted {
          for i in 0..<blockFrames {
            blockLeft[i] += songLeft[i]
            blockRight[i] += songRight[i]
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
