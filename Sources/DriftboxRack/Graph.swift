import DriftboxDSP

// A plan, running. A port of `driftbox/packages/rack/src/graph.ts`: one block at a time, module
// by module in the plan's order, then the master stage — solo, mute, balance pan, a linked peak
// limiter and a soft ceiling. Everything is allocated when the graph is made; `process` walks
// tables of pointers and allocates nothing, locks nothing and touches no class.

struct CollapseOp {
  var into: UnsafeMutablePointer<Float>
  var from: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  var count: Int
}

struct TrimOp {
  var into: UnsafeMutablePointer<Float>
  var from: UnsafeMutablePointer<Float>
  var gain: UnsafeMutablePointer<Float>
}

struct NodeRuntime {
  var processor: RackProcessor
  var inlets: Slots
  var outlets: Slots
  var params: Slots
  var collapse: UnsafeMutablePointer<CollapseOp>
  var collapseCount: Int
  var trims: UnsafeMutablePointer<TrimOp>
  var trimCount: Int
  var data: DataSlots
  var voiceInlets: VoiceInlets?
  var inletConnected: Flags
  var outletConnected: Flags
  var voice: VoiceInfo
}

struct OutputRuntime {
  var signal: UnsafeMutablePointer<Float>
  var right: UnsafeMutablePointer<Float>?
  var pan: UnsafeMutablePointer<Float>?
  var mute: UnsafeMutablePointer<Float>?
  var solo: UnsafeMutablePointer<Float>?
}

struct ScheduledParam {
  var slot: Int
  var value: Float
  /// -1 for every voice.
  var voice: Int
  var frame: Int
}

public struct RackGraph: ~Copyable {
  public let sampleRate: Double
  public let frames: Int
  /// Module types the plan named that this build cannot make. Should always be empty: the
  /// compiler checked the same registry.
  public private(set) var missing: [String] = []

  /// Everything allocated, to be freed with the graph. Never touched while rendering.
  private var owned: [UnsafeMutableRawPointer] = []
  /// Each module's data table, by id, and the slot names in it: what `setData` looks up.
  private var dataTables: [String: (table: UnsafeMutablePointer<DataBuffer>, slots: [String])] = [:]
  private var dataRevision = 0

  let nodes: UnsafeMutablePointer<NodeRuntime>
  let nodeCount: Int
  /// Each runtime's id — a module's, or `id#n` for its later voices — in the same order.
  let nodeIds: [String]
  /// The metered modules' mirrors, the runtime each copies, and the module ids, in that order.
  let mirrors: UnsafeMutablePointer<MeterMirror>
  let mirrorNodes: UnsafeMutablePointer<Int>
  let mirrorCount: Int
  public let meterIds: [String]
  let outputs: UnsafeMutablePointer<OutputRuntime>
  let outputCount: Int

  /// Per param slot, per voice: slot-major, `voiceCapacity` wide.
  let paramCount: Int
  let voiceCapacity: Int
  let paramBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  let values: UnsafeMutablePointer<Float>
  let targets: UnsafeMutablePointer<Float>
  let ramped: UnsafeMutablePointer<Bool>
  let rampAt: UnsafeMutablePointer<Int>
  let stepped: UnsafeMutablePointer<Bool>

  static var schedulingCapacity: Int { 512 }
  let scheduled: UnsafeMutablePointer<ScheduledParam>
  var scheduledCount = 0
  let due: UnsafeMutablePointer<ScheduledParam>

  var limitEnvelope = 0.0
  var limitGain = 1.0
  var tempo = 120.0
  var running = false
  var beat = 0.0
  var shuffle = 0.0
  /// Frames since the graph started: the clock a scheduled param is placed against.
  public internal(set) var frame = 0

  public init(
    plan: Plan, sampleRate: Double, frames: Int = 128, registry: [String: ModuleDef] = RackModules.registry
  ) {
    self.sampleRate = sampleRate
    self.frames = frames > 0 ? frames : 128
    let frames = self.frames
    var owned: [UnsafeMutableRawPointer] = []
    func floats(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
      pointer.initialize(repeating: value, count: max(1, count))
      owned.append(UnsafeMutableRawPointer(pointer))
      return pointer
    }
    func table<T>(_ items: [T]) -> UnsafeMutablePointer<T> {
      let pointer = UnsafeMutablePointer<T>.allocate(capacity: max(1, items.count))
      pointer.initialize(from: items, count: items.count)
      owned.append(UnsafeMutableRawPointer(pointer))
      return pointer
    }
    let scratch = floats(frames)

    let voices = max(1, min(8, plan.voices))
    var capacity = voices
    for width in plan.voiceWidths { capacity = max(capacity, width) }
    for node in plan.nodes { capacity = max(capacity, node.voices) }
    capacity = max(1, min(maximumRenderVoices, capacity))
    voiceCapacity = capacity

    // Buffers, one per voice of each.
    var buffers: [[UnsafeMutablePointer<Float>]] = []
    for index in 0..<plan.buffers {
      let described = index < plan.voiceWidths.count ? plan.voiceWidths[index] : 1
      let wide = max(1, min(capacity, described))
      buffers.append((0..<wide).map { _ in floats(frames) })
    }
    func at(_ index: Int, _ voice: Int) -> UnsafeMutablePointer<Float> {
      guard index >= 0, index < buffers.count else { return scratch }
      let perVoice = buffers[index]
      return perVoice[perVoice.count == 1 ? 0 : (voice < perVoice.count ? voice : 0)]
    }

    // Params.
    let paramTotal = plan.params.count
    paramCount = paramTotal
    let slotsWide = paramTotal * capacity
    values = floats(slotsWide)
    targets = floats(slotsWide)
    let rampedFlags = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, slotsWide))
    rampedFlags.initialize(repeating: false, count: max(1, slotsWide))
    owned.append(UnsafeMutableRawPointer(rampedFlags))
    ramped = rampedFlags
    let offsets = UnsafeMutablePointer<Int>.allocate(capacity: max(1, slotsWide))
    offsets.initialize(repeating: 0, count: max(1, slotsWide))
    owned.append(UnsafeMutableRawPointer(offsets))
    rampAt = offsets
    stepped = table(plan.params.map { $0.stepped })
    var paramPointers: [UnsafeMutablePointer<Float>] = []
    for (slot, param) in plan.params.enumerated() {
      for voice in 0..<capacity {
        let value = Float(param.value)
        values[slot * capacity + voice] = value
        targets[slot * capacity + voice] = value
        paramPointers.append(floats(frames, value))
      }
    }
    paramBuffers = table(paramPointers)
    func paramBuffer(_ slot: Int, _ voice: Int) -> UnsafeMutablePointer<Float> {
      guard slot >= 0, slot < paramTotal else { return scratch }
      return paramPointers[slot * capacity + min(voice, capacity - 1)]
    }

    // Nodes: one per voice of each polyphonic module, one for the rest.
    var runtimes: [NodeRuntime] = []
    // Which module each runtime is, for the ones a faceplate reads from.
    var runtimeIds: [String] = []
    var missing: [String] = []
    var dataTables: [String: (table: UnsafeMutablePointer<DataBuffer>, slots: [String])] = [:]
    var revision = 0
    for node in plan.nodes {
      guard let definition = registry[node.type] else {
        missing.append(node.type)
        continue
      }
      let poly = node.poly
      let instances = poly ? max(1, min(capacity, node.voices)) : 1
      let lanes = poly ? max(1, min(8, node.voiceLanes)) : 1
      // Data, seeded from the patch and shared by every voice; the host can replace a slot.
      let dataTable = UnsafeMutablePointer<DataBuffer>.allocate(capacity: max(1, definition.dataSlots.count))
      owned.append(UnsafeMutableRawPointer(dataTable))
      for (slot, name) in definition.dataSlots.enumerated() {
        if let values = node.data[name] {
          let copy = floats(values.count)
          for (index, value) in values.enumerated() { copy[index] = Float(value) }
          revision += 1
          dataTable[slot] = DataBuffer(samples: UnsafePointer(copy), count: values.count, revision: revision)
        } else {
          dataTable[slot] = DataBuffer(samples: nil, count: 0, revision: 0)
        }
      }
      dataTables[node.id] = (dataTable, definition.dataSlots)
      let shared: UnsafeMutablePointer<Double>? =
        definition.sharedDoubles > 0
        ? {
          let pointer = UnsafeMutablePointer<Double>.allocate(capacity: definition.sharedDoubles)
          pointer.initialize(repeating: 0, count: definition.sharedDoubles)
          owned.append(UnsafeMutableRawPointer(pointer))
          return pointer
        }() : nil
      for voice in 0..<instances {
        var voiceInletSlots: [Slots] = []
        var collapse: [CollapseOp] = []
        var trims: [TrimOp] = []
        var inlets: [UnsafeMutablePointer<Float>] = []
        for (inlet, index) in node.inlets.enumerated() {
          var source: UnsafeMutablePointer<Float>
          let width = index >= 0 && index < buffers.count ? buffers[index].count : 1
          let trimSlot = inlet < node.inletTrims.count ? node.inletTrims[inlet] : nil
          if !poly && node.collectVoices {
            // Every voice on its own, trimmed where the jack's pot says, beside the sum.
            let perVoice = index >= 0 && index < buffers.count ? buffers[index] : [scratch]
            let gathered: [UnsafeMutablePointer<Float>] = perVoice.map { from in
              guard let trimSlot else { return from }
              let into = floats(frames)
              trims.append(TrimOp(into: into, from: from, gain: paramBuffer(trimSlot, 0)))
              return into
            }
            voiceInletSlots.append(Slots(base: table(gathered), count: gathered.count))
          }
          if poly {
            let mapped = width <= 1 ? 0 : min(width - 1, (voice * width) / instances)
            source = at(index, mapped)
          } else if width > 1 {
            // A module that runs once, reading every voice of a polyphonic source: the sum.
            source = floats(frames)
            collapse.append(CollapseOp(into: source, from: table(buffers[index]), count: width))
          } else {
            source = at(index, 0)
          }
          if let slot = trimSlot {
            let into = floats(frames)
            trims.append(TrimOp(into: into, from: source, gain: paramBuffer(slot, poly ? voice : 0)))
            source = into
          }
          inlets.append(source)
        }
        let outlets = node.outlets.map { $0 > 0 ? at($0, voice) : scratch }
        let params = node.params.map { paramBuffer($0, poly ? voice : 0) }
        let id = voice == 0 ? node.id : "\(node.id)#\(voice)"
        let info = VoiceInfo(
          voice: voice, sourceVoice: voice / lanes, lane: voice % lanes, lanes: lanes, voices: instances,
          shared: shared, sharedCount: definition.sharedDoubles)
        guard let processor = RackModules.make(node.type, sampleRate: sampleRate, id: id, voice: info) else {
          missing.append(node.type)
          continue
        }
        runtimeIds.append(id)
        runtimes.append(
          NodeRuntime(
            processor: processor, inlets: Slots(base: table(inlets), count: inlets.count),
            outlets: Slots(base: table(outlets), count: outlets.count),
            params: Slots(base: table(params), count: params.count), collapse: table(collapse),
            collapseCount: collapse.count, trims: table(trims), trimCount: trims.count,
            data: DataSlots(base: dataTable, count: definition.dataSlots.count),
            voiceInlets: voiceInletSlots.isEmpty
              ? nil : VoiceInlets(base: table(voiceInletSlots), count: voiceInletSlots.count),
            inletConnected: Flags(base: table(node.inletConnected), count: node.inletConnected.count),
            outletConnected: Flags(base: table(node.outletConnected), count: node.outletConnected.count),
            voice: info))
      }
    }
    nodes = table(runtimes)
    nodeCount = runtimes.count
    nodeIds = runtimeIds

    // A mirror for each metered module, on its first voice: what its faceplate reads from.
    var mirrors: [MeterMirror] = []
    var mirrorNodes: [Int] = []
    var meterIds: [String] = []
    for (index, runtime) in runtimes.enumerated() where runtime.voice.voice == 0 {
      guard let mirror = MeterMirror.make(for: runtime.processor, sampleRate: sampleRate) else { continue }
      mirrors.append(mirror)
      mirrorNodes.append(index)
      meterIds.append(runtimeIds[index])
    }
    self.mirrors = table(mirrors)
    self.mirrorNodes = table(mirrorNodes)
    mirrorCount = mirrors.count
    self.meterIds = meterIds

    // Every voice of every terminal outlet.
    var outs: [OutputRuntime] = []
    for output in plan.outputs where output.buffer > 0 && output.buffer < buffers.count {
      let lefts = buffers[output.buffer]
      let rights = output.right.flatMap { $0 > 0 && $0 < buffers.count ? buffers[$0] : nil }
      func control(_ slot: Int?, _ voice: Int) -> UnsafeMutablePointer<Float>? {
        guard let slot, slot >= 0, slot < paramTotal else { return nil }
        return paramPointers[slot * capacity + min(voice, capacity - 1)]
      }
      for voice in lefts.indices {
        outs.append(
          OutputRuntime(
            signal: lefts[voice], right: rights.map { voice < $0.count ? $0[voice] : $0[0] },
            pan: control(output.pan, voice), mute: control(output.mute, voice),
            solo: control(output.solo, voice)))
      }
    }
    outputs = table(outs)
    outputCount = outs.count

    let queue = UnsafeMutablePointer<ScheduledParam>.allocate(capacity: Self.schedulingCapacity)
    owned.append(UnsafeMutableRawPointer(queue))
    scheduled = queue
    let dueQueue = UnsafeMutablePointer<ScheduledParam>.allocate(capacity: Self.schedulingCapacity)
    owned.append(UnsafeMutableRawPointer(dueQueue))
    due = dueQueue

    self.missing = missing
    self.dataTables = dataTables
    dataRevision = revision
    self.owned = owned
  }

  deinit {
    for index in 0..<nodeCount { nodes[index].processor.release() }
    for index in 0..<mirrorCount { mirrors[index].release() }
    for pointer in owned { pointer.deallocate() }
  }

  // MARK: - Control

  /// Aim a param at `value`, ramped across the next block — or, with a `frame`, from that sample.
  /// A nil `voice` is every voice, which is what a knob means.
  @_noAllocation
  public mutating func setParam(slot: Int, value: Double, voice: Int? = nil, frame: Int? = nil) {
    guard slot >= 0, slot < paramCount, value.isFinite else { return }
    if let voice, voice < 0 || voice >= voiceCapacity { return }
    guard let frame else {
      aim(slot, Float(value), voice ?? -1, 0)
      return
    }
    if scheduledCount >= Self.schedulingCapacity {
      // Full: the oldest waiting change lands now rather than being dropped.
      let oldest = scheduled[0]
      for index in 1..<scheduledCount { scheduled[index - 1] = scheduled[index] }
      scheduledCount -= 1
      aim(oldest.slot, oldest.value, oldest.voice, 0)
    }
    scheduled[scheduledCount] = ScheduledParam(
      slot: slot, value: Float(value), voice: voice ?? -1, frame: frame)
    scheduledCount += 1
  }

  @_noAllocation
  mutating func aim(_ slot: Int, _ value: Float, _ voice: Int, _ offset: Int) {
    let base = slot * voiceCapacity
    if voice < 0 {
      for index in 0..<voiceCapacity {
        targets[base + index] = value
        rampAt[base + index] = offset
      }
      return
    }
    targets[base + voice] = value
    rampAt[base + voice] = offset
  }

  /// Everything scheduled inside this block, in frame order, the later of two winning.
  @_noAllocation
  mutating func drain(blockStart: Int) {
    let blockEnd = blockStart + frames
    var dueCount = 0
    var kept = 0
    for index in 0..<scheduledCount {
      let event = scheduled[index]
      if event.frame >= blockEnd {
        scheduled[kept] = event
        kept += 1
      } else {
        // Insertion sort by frame, stable, into the due list.
        var at = dueCount
        while at > 0 && due[at - 1].frame > event.frame {
          due[at] = due[at - 1]
          at -= 1
        }
        due[at] = event
        dueCount += 1
      }
    }
    scheduledCount = kept
    for index in 0..<dueCount {
      let event = due[index]
      let offset = event.frame <= blockStart ? 0 : min(frames - 1, event.frame - blockStart)
      aim(event.slot, event.value, event.voice, offset)
    }
  }

  /// Tempo, and whether the transport runs. Starting from a stop rewinds the beat.
  @_noAllocation
  public mutating func setTransport(tempo: Double, running: Bool, shuffle: Double = 0) {
    if tempo.isFinite, tempo > 0 { self.tempo = max(20, min(400, tempo)) }
    if shuffle.isFinite { self.shuffle = max(0, min(1, shuffle)) }
    if running && !self.running { beat = 0 }
    self.running = running
  }

  /// Put the clock at `beat`, running or not, without the rewind a start from a stop has: an app
  /// the rack plays inside says where its own transport is.
  @_noAllocation
  public mutating func locate(beat: Double, running: Bool) {
    if beat.isFinite { self.beat = max(0, beat) }
    self.running = running
  }

  public var beatPosition: Double { beat }

  // MARK: - Rendering

  /// Replace one data slot of a module: a sample loaded, a pattern drawn. Copied, and kept until
  /// the graph goes. Not for the render thread.
  public mutating func setData(module: String, slot: String, samples: [Float]) {
    guard let entry = dataTables[module], let index = entry.slots.firstIndex(of: slot) else { return }
    let copy = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
    copy.initialize(from: samples, count: samples.count)
    owned.append(UnsafeMutableRawPointer(copy))
    dataRevision += 1
    entry.table[index] = DataBuffer(
      samples: UnsafePointer(copy), count: samples.count, revision: dataRevision)
  }

  /// Where a `plugin` or `plugin-instrument` module's processor is held, for a host to put one in:
  /// directly before the graph is handed over, and from the render thread after.
  public func externalEntry(module: String) -> UnsafeMutablePointer<ExternalSlot>? {
    for index in 0..<nodeCount where nodeIds[index] == module {
      switch nodes[index].processor {
      case .external(let processor): return processor.slot
      case .instrument(let processor): return processor.external.slot
      default: continue
      }
    }
    return nil
  }

  /// Where one module's data slot is held, for a host to swap a new buffer into from the render
  /// thread: `setData` allocates, so it may not be called there.
  public func dataEntry(module: String, slot: String) -> UnsafeMutablePointer<DataBuffer>? {
    guard let entry = dataTables[module], let index = entry.slots.firstIndex(of: slot) else { return nil }
    return entry.table + index
  }

  /// Copy what every metered module shows into its mirror. Cheap and allocation-free, so a host
  /// can do it from the render thread every few blocks.
  @_noAllocation
  public mutating func snapshotMeters() {
    for index in 0..<mirrorCount { mirrors[index].take(from: nodes[mirrorNodes[index]].processor) }
  }

  /// What the mirrors hold, by module id: as of the last snapshot, and on any thread, since
  /// nothing here reads a processor.
  public func meterReadings() -> [(id: String, reading: MeterReading)] {
    (0..<mirrorCount).flatMap { mirrors[$0].readings(id: meterIds[$0]) }
  }

  /// What the modules that show anything are showing now, by module id.
  public mutating func meters() -> [(id: String, reading: MeterReading)] {
    snapshotMeters()
    return meterReadings()
  }

  /// One block of `frames` frames into `left` and `right`, with the host's input buses.
  @_noAllocation
  public mutating func process(
    left mix: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
    host: HostInputs = .none
  ) {
    let frames = self.frames
    let blockStart = frame
    frame = blockStart + frames
    if scheduledCount > 0 { drain(blockStart: blockStart) }

    // Knobs: a ramp across the block after a change, then flat again.
    for slot in 0..<paramCount {
      let isStepped = stepped[slot]
      for voice in 0..<voiceCapacity {
        let index = slot * voiceCapacity + voice
        let buffer = paramBuffers[index]
        let target = targets[index]
        let value = values[index]
        let offset = rampAt[index]
        if value == target {
          if ramped[index] {
            buffer.update(repeating: target, count: frames)
            ramped[index] = false
          }
          continue
        }
        if isStepped {
          if offset > 0 {
            buffer.update(repeating: value, count: offset)
            // The old value is at the head of the buffer now, so the next block must fill it again,
            // or every block after keeps the old setting up to the offset for as long as this holds:
            // emmettl/driftbox#309.
            ramped[index] = true
          }
          (buffer + offset).update(repeating: target, count: frames - offset)
        } else {
          if offset > 0 { buffer.update(repeating: value, count: offset) }
          let span = frames - offset
          let step = (Double(target) - Double(value)) / Double(span)
          for i in 0..<span { buffer[offset + i] = Float(Double(value) + step * Double(i + 1)) }
          ramped[index] = true
        }
        values[index] = target
      }
    }

    let transport = Transport(
      tempo: tempo, running: running, beat: beat,
      beatsPerBlock: running ? Double(frames) * tempo / (60 * sampleRate) : 0,
      shuffle: shuffle)
    beat += transport.beatsPerBlock

    for index in 0..<nodeCount {
      let node = nodes[index]
      for op in 0..<node.collapseCount {
        let collapse = node.collapse[op]
        let first = collapse.from[0]
        for i in 0..<frames { collapse.into[i] = first[i] }
        var source = 1
        while source < collapse.count {
          let other = collapse.from[source]
          for i in 0..<frames { collapse.into[i] = Float(Double(collapse.into[i]) + Double(other[i])) }
          source += 1
        }
      }
      for op in 0..<node.trimCount {
        let trim = node.trims[op]
        for i in 0..<frames { trim.into[i] = Float(Double(trim.from[i]) * Double(trim.gain[i])) }
      }
      let context = ProcessContext(
        frames: frames, transport: transport, data: node.data, host: host, voiceInlets: node.voiceInlets,
        inletConnected: node.inletConnected, outletConnected: node.outletConnected, voice: node.voice)
      nodes[index].processor.process(
        inlets: node.inlets, outlets: node.outlets, params: node.params, context: context)
    }

    if outputCount == 0 {
      mix.update(repeating: 0, count: frames)
      right.update(repeating: 0, count: frames)
      return
    }

    // A millisecond to catch a transient, a tenth of a second to let go.
    let attack = expDSP(-1 / (0.001 * sampleRate))
    let release = expDSP(-1 / (0.1 * sampleRate))
    for i in 0..<frames {
      var soloed = false
      for o in 0..<outputCount {
        if let solo = outputs[o].solo, solo[i] >= 0.5 {
          soloed = true
          break
        }
      }
      var left = 0.0
      var rightSum = 0.0
      for o in 0..<outputCount {
        let output = outputs[o]
        if let mute = output.mute, mute[i] >= 0.5 { continue }
        if soloed && !(output.solo.map { $0[i] >= 0.5 } ?? false) { continue }
        let sample = Double(output.signal[i])
        let other = output.right.map { Double($0[i]) } ?? sample
        guard let panBuffer = output.pan else {
          left += sample
          rightSum += other
          continue
        }
        var pan = Double(panBuffer[i])
        if pan < -1 { pan = -1 } else if pan > 1 { pan = 1 }
        // Balance, not equal power: unity on both at centre.
        left += pan <= 0 ? sample : sample * (1 - pan)
        rightSum += pan >= 0 ? other : other * (1 + pan)
      }
      if !left.isFinite { left = 0 }
      if !rightSum.isFinite { rightSum = 0 }

      // The master limiter, linked across the pair.
      let peak = max(left < 0 ? -left : left, rightSum < 0 ? -rightSum : rightSum)
      let coefficient = peak > limitEnvelope ? attack : release
      limitEnvelope = peak + (limitEnvelope - peak) * coefficient
      let wanted = limitEnvelope > 0.95 ? 0.95 / limitEnvelope : 1
      limitGain = wanted < limitGain ? wanted : wanted + (limitGain - wanted) * release
      left *= limitGain
      rightSum *= limitGain

      let outLeft = Self.ceiling(left)
      let outRight = Self.ceiling(rightSum)
      mix[i] = Float(outLeft > 4 ? 4 : outLeft < -4 ? -4 : outLeft)
      right[i] = Float(outRight > 4 ? 4 : outRight < -4 ? -4 : outRight)
    }
  }

  /// Anything above the limiter's own threshold bent towards 1; below it, the identity.
  @_noAllocation
  static func ceiling(_ x: Double) -> Double {
    let knee = 0.95
    let magnitude = x < 0 ? -x : x
    if magnitude <= knee { return x }
    let over = (magnitude - knee) / (1 - knee)
    let bent = knee + (1 - knee) * tanhDSP(over)
    return x < 0 ? -bent : bent
  }
}
