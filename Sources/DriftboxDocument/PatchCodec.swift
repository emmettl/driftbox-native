import DriftboxRack

/// A rack patch as text and back, in the web's format. A port of
/// `driftbox/packages/rack/src/patch-io.ts`.
///
/// Decoding repairs rather than refuses, as the song codec does: a module without an id or a
/// type is dropped and the rest kept, a cable to a module that is not there is dropped, a knob
/// that is not a number is forgotten. It gives up only when what it was handed is not a patch —
/// not JSON, no module list — or is from a newer format than this one. Held to the reference on
/// every factory patch and a set of damaged ones, byte for byte, in `conformance/fixtures/rack`.
public enum PatchCodec {
  public static let format = 2

  public static func encode(_ patch: Patch) -> String {
    var envelope = JSONObject()
    envelope["v"] = .number(Double(format))
    envelope["patch"] = json(patch)
    return JSONValue.object(envelope).text
  }

  public static func decode(_ text: String) -> Patch? {
    guard let parsed = JSONValue(parsing: text)?.object else { return nil }
    if case .number(let version)? = parsed["v"], version > Double(format) { return nil }
    let body = parsed["patch"]?.object ?? parsed
    return patch(from: body)
  }

  /// A patch from a parsed body, repaired as `decode` repairs it.
  public static func patch(from body: JSONObject) -> Patch? {
    guard let rawModules = body["modules"]?.array else { return nil }

    var modules: [PatchModule] = []
    var ids: Set<String> = []
    for raw in rawModules {
      guard let parsedModule = module(raw), !ids.contains(parsedModule.id) else { continue }
      ids.insert(parsedModule.id)
      modules.append(parsedModule)
    }

    var cables: [PatchCable] = []
    var seen: Set<[String]> = []
    for raw in body["cables"]?.array ?? [] {
      guard let cable = raw.object, let from = endpoint(cable["from"]), let to = endpoint(cable["to"]),
        ids.contains(from.module), ids.contains(to.module)
      else { continue }
      let key = [from.module, from.port, to.module, to.port]
      if seen.contains(key) { continue }
      seen.insert(key)
      cables.append(PatchCable(from: from, to: to))
    }

    var modulation: [ModRoute] = []
    for raw in body["modulation"]?.array ?? [] {
      guard let route = raw.object, let from = endpoint(route["from"]), let to = endpoint(route["to"]),
        ids.contains(from.module), ids.contains(to.module)
      else { continue }
      modulation.append(ModRoute(from: from, to: to, min: route["min"]?.finite, max: route["max"]?.finite))
    }

    var automation: [AutomationLane] = []
    for raw in body["automation"]?.array ?? [] {
      guard let lane = raw.object, let target = endpoint(lane["target"]), ids.contains(target.module) else {
        continue
      }
      var points: [(at: Int, value: Double)] = []
      for rawPoint in lane["points"]?.array ?? [] {
        guard let point = rawPoint.object, let at = point["at"]?.finite, at >= 0,
          let value = point["value"]?.finite
        else { continue }
        points.append((Int((at + 0.5).rounded(.down)), value))
      }
      if points.isEmpty { continue }
      // `Array.prototype.sort` is stable, and so is this.
      points = points.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(
        \.element)
      automation.append(
        AutomationLane(target: target, points: points, holds: lane["curve"]?.string == "hold"))
    }

    var patch = Patch(modules: modules, cables: cables)
    if let visual = body["visual"]?.string {
      let trimmed = jsTrim(visual)
      if !trimmed.isEmpty { patch.visual = jsPrefix(trimmed, 120) }
    }
    if let breakId = body["break"]?.string, !breakId.isEmpty { patch.breakId = breakId }
    if let groovebox = body["groovebox"]?.string, !groovebox.isEmpty { patch.groovebox = groovebox }
    patch.modulation = modulation
    if let voices = body["voices"]?.finite, voices == voices.rounded(.towardZero), voices > 1, voices <= 8 {
      patch.voices = voices
    }
    patch.automation = automation
    if let tempo = body["tempo"]?.finite, tempo >= 20, tempo <= 400 { patch.tempo = tempo }
    return patch
  }

  private static func endpoint(_ value: JSONValue?) -> PortReference? {
    guard let parts = value?.array, parts.count >= 2, let module = parts[0].string, !module.isEmpty,
      let port = parts[1].string, !port.isEmpty
    else { return nil }
    return PortReference(module, port)
  }

  private static func numbers(_ value: JSONValue?) -> KeyedList<Double>? {
    guard let object = value?.object else { return nil }
    var out: KeyedList<Double> = [:]
    for (key, raw) in object.members {
      if let number = raw.finite { out[key] = number }
    }
    return out.isEmpty ? nil : out
  }

  private static func module(_ value: JSONValue) -> PatchModule? {
    guard let object = value.object, let id = object["id"]?.string, !id.isEmpty,
      let type = object["type"]?.string, !type.isEmpty
    else { return nil }
    var out = PatchModule(id: id, type: type)
    if let version = object["version"]?.finite, version == version.rounded(.towardZero), version > 0 {
      out.version = Int(version)
    }
    if let knobs = numbers(object["params"]) { out.params = knobs }
    if let data = object["data"]?.object {
      for (slot, raw) in data.members {
        guard let entries = raw.array else { continue }
        let finite = entries.compactMap(\.finite)
        // A slot with anything but numbers in it is dropped whole: a pattern with a hole in it
        // is a different pattern.
        if finite.count == entries.count { out.data[slot] = finite }
      }
    }
    if let trims = numbers(object["inputTrims"]) { out.inputTrims = trims }
    if let position = object["pos"]?.array, position.count >= 2, let x = position[0].finite,
      let y = position[1].finite
    {
      out.position = [x, y]
    }
    out.bypassed = object["bypassed"]?.bool == true
    if let plugin = object["plugin"]?.object, let format = plugin["format"]?.string, !format.isEmpty,
      let id = plugin["id"]?.string, !id.isEmpty
    {
      out.plugin = PluginReference(
        format: format, id: id, name: plugin["name"]?.string ?? "", vendor: plugin["vendor"]?.string ?? "",
        state: plugin["state"]?.string)
    }
    return out
  }

  // MARK: - Writing, in the order the reference's decoder builds its objects

  private static func json(_ patch: Patch) -> JSONValue {
    var out = JSONObject()
    out["modules"] = .array(patch.modules.map(json))
    out["cables"] = .array(
      patch.cables.map { cable in
        var object = JSONObject()
        object["from"] = json(cable.from)
        object["to"] = json(cable.to)
        return .object(object)
      })
    if let visual = patch.visual { out["visual"] = .string(visual) }
    if let breakId = patch.breakId { out["break"] = .string(breakId) }
    if let groovebox = patch.groovebox { out["groovebox"] = .string(groovebox) }
    if !patch.modulation.isEmpty {
      out["modulation"] = .array(
        patch.modulation.map { route in
          var object = JSONObject()
          object["from"] = json(route.from)
          object["to"] = json(route.to)
          if let min = route.min { object["min"] = .number(min) }
          if let max = route.max { object["max"] = .number(max) }
          return .object(object)
        })
    }
    if let voices = patch.voices { out["voices"] = .number(voices) }
    if !patch.automation.isEmpty {
      out["automation"] = .array(
        patch.automation.map { lane in
          var object = JSONObject()
          object["target"] = json(lane.target)
          object["points"] = .array(
            lane.points.map { point in
              var entry = JSONObject()
              entry["at"] = .number(Double(point.at))
              entry["value"] = .number(point.value)
              return .object(entry)
            })
          if lane.holds { object["curve"] = .string("hold") }
          return .object(object)
        })
    }
    if let tempo = patch.tempo { out["tempo"] = .number(tempo) }
    return .object(out)
  }

  private static func json(_ module: PatchModule) -> JSONValue {
    var out = JSONObject()
    out["id"] = .string(module.id)
    out["type"] = .string(module.type)
    if let version = module.version { out["version"] = .number(Double(version)) }
    if !module.params.isEmpty { out["params"] = numbers(module.params) }
    if !module.data.isEmpty {
      var data = JSONObject()
      for (slot, values) in module.data { data[slot] = .array(values.map { .number($0) }) }
      out["data"] = .object(data)
    }
    if !module.inputTrims.isEmpty { out["inputTrims"] = numbers(module.inputTrims) }
    if let position = module.position { out["pos"] = .array(position.map { .number($0) }) }
    if module.bypassed { out["bypassed"] = .bool(true) }
    // Native only: the reference keeps a module of a type it does not know, but not this.
    if let plugin = module.plugin {
      var object = JSONObject()
      object["format"] = .string(plugin.format)
      object["id"] = .string(plugin.id)
      object["name"] = .string(plugin.name)
      object["vendor"] = .string(plugin.vendor)
      if let state = plugin.state { object["state"] = .string(state) }
      out["plugin"] = .object(object)
    }
    return .object(out)
  }

  private static func numbers(_ list: KeyedList<Double>) -> JSONValue {
    var object = JSONObject()
    for (key, value) in list { object[key] = .number(value) }
    return .object(object)
  }

  private static func json(_ reference: PortReference) -> JSONValue {
    .array([.string(reference.module), .string(reference.port)])
  }
}
