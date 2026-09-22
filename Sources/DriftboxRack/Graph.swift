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

  let nodes: UnsafeMutablePointer<NodeRuntime>
  let nodeCount: Int
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
    var missing: [String] = []
    for node in plan.nodes {
      guard registry[node.type] != nil else {
        missing.append(node.type)
        continue
      }
      let poly = node.poly
      let instances = poly ? max(1, min(capacity, node.voices)) : 1
      for voice in 0..<instances {
        var collapse: [CollapseOp] = []
        var trims: [TrimOp] = []
        var inlets: [UnsafeMutablePointer<Float>] = []
        for (inlet, index) in node.inlets.enumerated() {
          var source: UnsafeMutablePointer<Float>
          let width = index >= 0 && index < buffers.count ? buffers[index].count : 1
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
          if inlet < node.inletTrims.count, let slot = node.inletTrims[inlet] {
            let into = floats(frames)
            trims.append(TrimOp(into: into, from: source, gain: paramBuffer(slot, poly ? voice : 0)))
            source = into
          }
          inlets.append(source)
        }
        let outlets = node.outlets.map { $0 > 0 ? at($0, voice) : scratch }
        let params = node.params.map { paramBuffer($0, poly ? voice : 0) }
        let id = voice == 0 ? node.id : "\(node.id)#\(voice)"
        guard let processor = RackModules.make(node.type, sampleRate: sampleRate, id: id) else {
          missing.append(node.type)
          continue
        }
        runtimes.append(
          NodeRuntime(
            processor: processor, inlets: Slots(base: table(inlets), count: inlets.count),
            outlets: Slots(base: table(outlets), count: outlets.count),
            params: Slots(base: table(params), count: params.count), collapse: table(collapse),
            collapseCount: collapse.count, trims: table(trims), trimCount: trims.count))
      }
    }
    nodes = table(runtimes)
    nodeCount = runtimes.count

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
    self.owned = owned
  }

  deinit {
    for index in 0..<nodeCount { nodes[index].processor.release() }
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

  public var beatPosition: Double { beat }

  // MARK: - Rendering

  /// One block of `frames` frames into `left` and `right`.
  @_noAllocation
  public mutating func process(left mix: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
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
          if offset > 0 { buffer.update(repeating: value, count: offset) }
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
      nodes[index].processor.process(
        inlets: node.inlets, outlets: node.outlets, params: node.params, frames: frames, transport: transport)
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
