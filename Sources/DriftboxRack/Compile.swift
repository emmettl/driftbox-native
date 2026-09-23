import DriftboxDSP

// Turning a patch into something the render thread can run without thinking. A port of
// `driftbox/packages/rack/src/compile.ts`, which has the reasoning for every rule here: the
// ordering, the cycle breaking, which buffer each cable is. It runs when a patch changes, never
// per block, so it may allocate; `RackGraph` then does nothing but walk the list it makes.
//
// It never fails. A patch arrives from outside the program, and anything unusable in it is
// dropped or neutralised and written down in `notes`.

public struct PlanNode: Equatable, Sendable {
  public var id: String
  public var type: String
  /// Buffer indices, one per processor slot: a stereo port takes two.
  public var inlets: [Int]
  public var inletConnected: [Bool]
  /// A param slot for an inlet's trim, where one is doing something.
  public var inletTrims: [Int?]
  public var outlets: [Int]
  public var outletConnected: [Bool]
  public var params: [Int]
  public var poly: Bool
  public var voices: Int
  public var voiceLanes: Int
  public var collectVoices: Bool
  /// The patch's own data for the module, carried through untouched.
  public var data: KeyedList<[Double]>
}

public struct PlanOutput: Equatable, Sendable {
  public var buffer: Int
  public var right: Int?
  public var pan: Int?
  public var mute: Int?
  public var solo: Int?
}

public struct PlanParam: Equatable, Sendable {
  public var value: Double
  public var stepped: Bool
}

public struct PlanNote: Equatable, Sendable {
  public var kind: String
  public var module: String?
  public var detail: String
}

public struct Plan: Sendable {
  public var buffers: Int
  public var voices: Int
  public var poly: [Bool]
  public var voiceWidths: [Int]
  public var nodes: [PlanNode]
  public var outputs: [PlanOutput]
  public var params: [PlanParam]
  /// Module id to param id to slot: what `setParam` looks a knob up by.
  public var slots: [String: [String: Int]]
  /// Module id to inlet id to the slot of its trim, where it has one: what `setTrim` looks a pot up by.
  public var inputTrims: [String: [String: Int]]
  public var notes: [PlanNote]
}

/// Buffer 0 is the zero buffer. Nothing writes it, so an unconnected inlet reads silence.
let zeroBuffer = 0
/// Eight notes through an eight-lane chord expander.
let maximumRenderVoices = 64

func clampParam(_ value: Double?, _ low: Double, _ high: Double, _ fallback: Double) -> Double {
  guard let value, value.isFinite else { return fallback }
  return max(low, min(high, value))
}

/// The buffers a destination port reads, given the ones its source writes: mono into stereo is
/// the same buffer twice, stereo into mono is its left.
func wire(_ source: [Int], _ want: Int) -> [Int] {
  let left = source.first ?? zeroBuffer
  if want == 1 { return [left] }
  return [left, source.count > 1 ? source[1] : left]
}

/// A cable may name a port by its current id or by one it used to have.
func portMatch(_ ports: [Port], _ id: String) -> (port: Port, channel: Int?, aliased: Bool)? {
  if let current = ports.first(where: { $0.id == id }) { return (current, nil, false) }
  for port in ports {
    if let alias = port.aliases.first(where: { $0.id == id }) { return (port, alias.channel, true) }
  }
  return nil
}

/// Compile `patch` against the modules in `registry`.
public func compile(_ rawPatch: Patch, registry: [String: ModuleDef] = RackModules.registry) -> Plan {
  var notes: [PlanNote] = []
  // Combinator routings, baked into the params before anything else looks at one.
  let patch = applyModulation(rawPatch, registry: registry)
  let voices = Int(max(1, min(8, jsRound(clampParam(patch.voices, 1, 8, 1)))))

  // ---- Modules: an unknown type is a placeholder, kept so cables to it still resolve.
  struct Entry {
    var module: PatchModule
    var index: Int?
  }
  var entries: [String: Entry] = [:]
  var live: [PatchModule] = []
  for module in patch.modules {
    guard !module.id.isEmpty else { continue }
    if entries[module.id] != nil {
      notes.append(
        PlanNote(
          kind: "duplicate-module", module: module.id,
          detail: "two modules share the id \"\(module.id)\"; the later one was dropped"))
      continue
    }
    guard registry[module.type] != nil else {
      notes.append(
        PlanNote(
          kind: "placeholder", module: module.id,
          detail: "no module of type \"\(module.type)\" in this build; kept as a placeholder"))
      entries[module.id] = Entry(module: module, index: nil)
      continue
    }
    entries[module.id] = Entry(module: module, index: live.count)
    live.append(module)
  }
  func def(_ index: Int) -> ModuleDef { registry[live[index].type]! }

  // ---- Buffers: one per outlet channel of every live module, patched or not.
  var outletBuffer: [PortReference: [Int]] = [:]
  var bufferPoly: [Bool] = [false]
  var bufferOwner: [Int] = [-1]
  var buffers = 1
  for (moduleIndex, module) in live.enumerated() {
    let definition = def(moduleIndex)
    for port in definition.outlets {
      var channels: [Int] = []
      for _ in 0..<port.channels {
        bufferPoly.append(definition.poly)
        bufferOwner.append(moduleIndex)
        channels.append(buffers)
        buffers += 1
      }
      outletBuffer[PortReference(module.id, port.id)] = channels
    }
  }

  func outputChannels(_ entry: Entry, _ portId: String) -> [Int] {
    guard let index = entry.index, let match = portMatch(def(index).outlets, portId) else {
      return [zeroBuffer]
    }
    let channels = outletBuffer[PortReference(entry.module.id, match.port.id)] ?? [zeroBuffer]
    guard let channel = match.channel else { return channels }
    return [channel < channels.count ? channels[channel] : zeroBuffer]
  }

  // ---- Cables: one per inlet, and the last one wins.
  struct Source {
    var channels: [Int]
    var from: Int?
    var fromId: String
    var fromPort: String
    var fromCanonicalPort: String
    var to: Int
    var toId: String
    var toPort: String
  }
  // In the order each inlet was first patched, as a JavaScript Map keeps it.
  var inletKeys: [PortReference] = []
  var inletSource: [PortReference: Source] = [:]
  var replacedSeen: Set<PortReference> = []
  var placeholderOutletConnections: Set<PortReference> = []

  for cable in patch.cables {
    let (fromId, fromPort) = (cable.from.module, cable.from.port)
    let (toId, toPort) = (cable.to.module, cable.to.port)
    guard let source = entries[fromId] else {
      notes.append(
        PlanNote(kind: "dropped-cable", module: nil, detail: "no module \"\(fromId)\" to take a cable from"))
      continue
    }
    guard let dest = entries[toId] else {
      notes.append(
        PlanNote(kind: "dropped-cable", module: nil, detail: "no module \"\(toId)\" to take a cable to"))
      continue
    }
    let sourceMatch = source.index.flatMap { portMatch(def($0).outlets, fromPort) }
    let destMatch = dest.index.flatMap { portMatch(def($0).inlets, toPort) }
    if source.index != nil, sourceMatch == nil {
      notes.append(
        PlanNote(
          kind: "dropped-cable", module: nil, detail: "\(source.module.type) has no outlet \"\(fromPort)\""))
      continue
    }
    if dest.index != nil, destMatch == nil {
      notes.append(
        PlanNote(kind: "dropped-cable", module: nil, detail: "\(dest.module.type) has no inlet \"\(toPort)\"")
      )
      continue
    }
    let canonicalFromPort = sourceMatch?.port.id ?? fromPort
    let canonicalToPort = destMatch?.port.id ?? toPort
    guard let destIndex = dest.index else {
      placeholderOutletConnections.insert(PortReference(fromId, canonicalFromPort))
      continue
    }
    let key = PortReference(toId, canonicalToPort)
    if inletSource[key] != nil {
      if replacedSeen.contains(key) {
        notes.append(
          PlanNote(
            kind: "replaced-cable", module: nil,
            detail: "one cable per inlet: superseded by a later cable into \(toId).\(toPort)"))
      }
    } else {
      inletKeys.append(key)
    }
    replacedSeen.insert(key)
    inletSource[key] = Source(
      channels: source.index == nil ? [zeroBuffer] : outputChannels(source, fromPort), from: source.index,
      fromId: fromId, fromPort: fromPort, fromCanonicalPort: canonicalFromPort, to: destIndex, toId: toId,
      toPort: canonicalToPort)
  }

  var connectedOutlets = placeholderOutletConnections
  for key in inletKeys {
    let source = inletSource[key]!
    connectedOutlets.insert(PortReference(source.fromId, source.fromCanonicalPort))
  }

  // ---- Bypass: a bypassed module's outlets all answer with whatever reaches its first inlet.
  func bypassed(_ index: Int?) -> Bool { index.map { live[$0].bypassed } ?? false }

  func resolve(_ fromId: String, _ fromPort: String, _ seen: inout Set<String>) -> (
    channels: [Int], from: Int?
  ) {
    guard let entry = entries[fromId], let index = entry.index else { return ([zeroBuffer], nil) }
    if !bypassed(index) { return (outputChannels(entry, fromPort), index) }
    if seen.contains(fromId) { return ([zeroBuffer], nil) }
    seen.insert(fromId)
    guard let first = def(index).inlets.first,
      let feeding = inletSource[PortReference(fromId, first.id)]
    else { return ([zeroBuffer], nil) }
    return resolve(feeding.fromId, feeding.fromPort, &seen)
  }

  for key in inletKeys {
    var seen: Set<String> = []
    let source = inletSource[key]!
    let resolved = resolve(source.fromId, source.fromPort, &seen)
    inletSource[key]!.channels = resolved.channels
    inletSource[key]!.from = resolved.from
  }

  // ---- Order: Kahn's, the lowest-numbered ready module each time; on a cycle, the lowest
  // remaining one is forced out, and the cables it could not satisfy read last block's buffer.
  var successors = [[Int]](repeating: [], count: live.count)
  var indegree = [Int](repeating: 0, count: live.count)
  struct Edge: Hashable {
    var from: Int
    var to: Int
  }
  var edges: Set<Edge> = []
  for key in inletKeys {
    let source = inletSource[key]!
    guard let from = source.from, from != source.to else { continue }
    let edge = Edge(from: from, to: source.to)
    if edges.contains(edge) { continue }
    edges.insert(edge)
    successors[from].append(source.to)
    indegree[source.to] += 1
  }
  var order: [Int] = []
  var done = [Bool](repeating: false, count: live.count)
  while order.count < live.count {
    var pick = -1
    for i in 0..<live.count where !done[i] && indegree[i] == 0 {
      pick = i
      break
    }
    if pick == -1 {
      for i in 0..<live.count where !done[i] {
        pick = i
        break
      }
    }
    done[pick] = true
    order.append(pick)
    for next in successors[pick] where !done[next] { indegree[next] -= 1 }
  }
  var position = [Int](repeating: 0, count: live.count)
  for (at, module) in order.enumerated() { position[module] = at }

  // ---- Voice widths: polyphonic modules take the widest stream reaching them; an expander
  // multiplies it. Repeated to a fixed point because a feedback cable points backwards.
  var moduleVoices = live.indices.map { def($0).poly ? voices : 1 }
  var moduleLanes = [Int](repeating: 1, count: live.count)
  func sourceWidth(_ buffer: Int) -> Int {
    let owner = buffer < bufferOwner.count ? bufferOwner[buffer] : -1
    return owner < 0 ? 1 : moduleVoices[owner]
  }
  func expansion(_ definition: ModuleDef) -> Int {
    Int(max(1, min(8, jsRound(Double(definition.voiceExpansion ?? 1)))))
  }
  for _ in 0..<maximumRenderVoices {
    var changed = false
    for index in order {
      let definition = def(index)
      guard definition.poly else { continue }
      var incoming = voices
      for inlet in definition.inlets {
        let channels = inletSource[PortReference(live[index].id, inlet.id)]?.channels ?? [zeroBuffer]
        for channel in channels { incoming = max(incoming, sourceWidth(channel)) }
      }
      let asked = expansion(definition)
      let lanes = incoming * asked <= maximumRenderVoices ? asked : 1
      let width = incoming * lanes
      moduleLanes[index] = lanes
      if width > moduleVoices[index] {
        moduleVoices[index] = width
        changed = true
      }
    }
    if !changed { break }
  }
  let voiceWidths = (0..<buffers).map { sourceWidth($0) }
  for index in live.indices {
    let asked = expansion(def(index))
    if asked <= 1 || moduleLanes[index] == asked { continue }
    notes.append(
      PlanNote(
        kind: "voice-cap", module: live[index].id,
        detail:
          "\(live[index].id) kept \(moduleVoices[index]) voices: another \(asked)-lane expansion would exceed \(maximumRenderVoices)"
      ))
  }

  // ---- Params: slots in patch order, so a cable that reorders execution renumbers no knob.
  var params: [PlanParam] = []
  var slots: [String: [String: Int]] = [:]
  for (index, module) in live.enumerated() {
    var mine: [String: Int] = [:]
    for param in def(index).params {
      mine[param.id] = params.count
      params.append(
        PlanParam(
          value: clampParam(module.params[param.id], param.min, param.max, param.defaultValue),
          stepped: param.stepped))
    }
    slots[module.id] = mine
  }

  // ---- Input trims: a slot only where something is patched and the pot is off unity.
  var inputTrims: [String: [String: Int]] = [:]
  for (index, module) in live.enumerated() {
    var trims: [String: Int] = [:]
    for inlet in def(index).inlets {
      guard let source = inletSource[PortReference(module.id, inlet.id)],
        !source.channels.allSatisfy({ $0 == zeroBuffer })
      else { continue }
      let wanted = clampParam(module.inputTrims[inlet.id], -1, 1, 1)
      if wanted == 1 { continue }
      trims[inlet.id] = params.count
      params.append(PlanParam(value: wanted, stepped: false))
    }
    inputTrims[module.id] = trims
  }

  // ---- Nodes, in execution order; a bypassed module has none.
  let nodes: [PlanNode] = order.filter { !bypassed($0) }.map { index in
    let module = live[index]
    let definition = def(index)
    var inlets: [Int] = []
    var inletConnected: [Bool] = []
    var inletTrims: [Int?] = []
    for port in definition.inlets {
      let key = PortReference(module.id, port.id)
      inlets += wire(inletSource[key]?.channels ?? [zeroBuffer], port.channels)
      for _ in 0..<port.channels {
        inletConnected.append(inletSource[key] != nil)
        inletTrims.append(inputTrims[module.id]?[port.id])
      }
    }
    var outlets: [Int] = []
    var outletConnected: [Bool] = []
    for port in definition.outlets {
      outlets += outletBuffer[PortReference(module.id, port.id)] ?? [zeroBuffer]
      for _ in 0..<port.channels {
        outletConnected.append(connectedOutlets.contains(PortReference(module.id, port.id)))
      }
    }
    return PlanNode(
      id: module.id, type: module.type, inlets: inlets, inletConnected: inletConnected,
      inletTrims: inletTrims,
      outlets: outlets, outletConnected: outletConnected,
      params: definition.params.map { slots[module.id]![$0.id]! }, poly: definition.poly,
      voices: moduleVoices[index], voiceLanes: moduleLanes[index],
      collectVoices: !definition.poly && definition.voiceCollector, data: module.data)
  }

  var outputs: [PlanOutput] = []
  for (index, module) in live.enumerated() {
    let definition = def(index)
    guard definition.terminal, !module.bypassed, let port = definition.outlets.first,
      let channels = outletBuffer[PortReference(module.id, port.id)], let first = channels.first
    else { continue }
    func slot(_ id: String?) -> Int? { id.flatMap { slots[module.id]?[$0] } }
    outputs.append(
      PlanOutput(
        buffer: first, right: channels.count > 1 ? channels[1] : nil, pan: slot(definition.terminalPan),
        mute: slot(definition.terminalMute), solo: slot(definition.terminalSolo)))
  }

  // Cables that lost a channel, then cables that run backwards.
  for key in inletKeys {
    let source = inletSource[key]!
    guard source.channels.count >= 2 else { continue }
    guard let port = def(source.to).inlets.first(where: { $0.id == source.toPort }), port.channels <= 1 else {
      continue
    }
    notes.append(
      PlanNote(
        kind: "mono-fold", module: source.toId,
        detail: "\(source.toId).\(source.toPort) is mono: the left channel is heard and the right is not"))
  }
  for key in inletKeys {
    let source = inletSource[key]!
    guard let from = source.from else { continue }
    if from != source.to && position[from] < position[source.to] { continue }
    notes.append(
      PlanNote(
        kind: "delayed", module: source.toId,
        detail: "feedback into \(source.toId).\(source.toPort): delayed by one block to break the cycle"))
  }

  return Plan(
    buffers: buffers, voices: voices, poly: bufferPoly, voiceWidths: voiceWidths, nodes: nodes,
    outputs: outputs,
    params: params, slots: slots, inputTrims: inputTrims, notes: notes)
}
