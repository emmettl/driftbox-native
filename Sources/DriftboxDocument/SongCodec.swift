import DriftboxSeq

/// Turning a song into text and back, in the web app's format. A port of
/// `driftbox/packages/engine/src/song-io.ts`.
///
/// A song arrives from outside the program: written by an older build, edited by hand, sent by
/// somebody else. So decoding never fails on a value it can repair. It clamps numbers into range,
/// fills in what is missing, drops what it cannot understand, and gives up only when what it was
/// handed is not a song at all. A pattern with a corrupt step costs that step, not the session.
///
/// It is held to the reference two ways: every catalogue song decodes and encodes back to the same
/// bytes, and a set of damaged and legacy documents comes out exactly as the reference repairs
/// them. Both are in `conformance/fixtures`.
public enum SongCodec {
  /// Bumped when the shape changes in a way a reader cannot infer from the value alone. Older
  /// songs are migrated on the way in; everything is written in the current format.
  public static let format = 7

  public static func encode(_ song: Song) -> String {
    var envelope = JSONObject()
    envelope["v"] = .number(Double(format))
    envelope["song"] = json(song)
    return JSONValue.object(envelope).text
  }

  /// Nil only when the input is not a song: unparseable, the wrong shape, with no usable pattern,
  /// or from a format newer than this one — which is refused rather than guessed at.
  public static func decode(_ text: String) -> Song? {
    guard let parsed = JSONValue(parsing: text)?.object else { return nil }
    // A bare song loads as well as an enveloped one.
    let body = parsed["song"]?.object ?? parsed
    if case .number(let version)? = parsed["v"], version > Double(format) { return nil }

    let patterns = (body["patterns"]?.array ?? []).enumerated().compactMap { pattern($1, index: $0) }
    guard !patterns.isEmpty else { return nil }
    let ids = Set(patterns.map(\.id))

    let chain = (body["chain"]?.array ?? []).compactMap { entry -> ChainStep? in
      // A v1 chain is a bare list of pattern ids, each of them one bar.
      if let id = entry.string { return ChainStep(pattern: id) }
      guard let entry = entry.object, let id = entry["pattern"]?.string else { return nil }
      var step = ChainStep(pattern: id, repeat: Int(jsRound(clamp(entry["repeat"], 1, 64, 1))))
      if let clips = entry["clips"]?.object {
        for slot in ClipSlot.allCases {
          if let clip = clips[slot.name]?.string, ids.contains(clip) { step.clips[slot] = clip }
        }
      }
      return step
    }
    // An entry naming a pattern that is not here would play the first pattern rather than
    // nothing, which is worse than dropping it.
    .filter { ids.contains($0.pattern) }

    var visual: String?
    if let raw = body["visual"]?.string {
      let trimmed = jsTrim(raw)
      if !trimmed.isEmpty { visual = jsPrefix(trimmed, 120) }
    }

    return Song(
      bpm: jsRound(clamp(body["bpm"], 20, 300, 120)), swing: clamp(body["swing"], 0, 1, 0),
      visual: visual, patterns: patterns, chain: chain, kit: kit(body["kit"]),
      fx: knobs(body["fx"]), automation: automation(body["automation"]))
  }
}

// MARK: - Reading

/// Anything that is not a finite number falls back rather than being coerced.
private func clamp(_ value: JSONValue?, _ low: Double, _ high: Double, _ fallback: Double) -> Double {
  guard let number = value?.finite else { return fallback }
  return max(low, min(high, number))
}

private func knobs<Knobs: KnobSet>(_ value: JSONValue?) -> Knobs {
  let source = value?.object
  var out = Knobs.defaults
  for knob in 0..<Knobs.names.count {
    out[knob] = clamp(source?[Knobs.names[knob]], 0, 1, Knobs.defaults[knob])
  }
  return out
}

private func steps(_ value: JSONValue?, length: Int) -> [StepValue]? {
  guard let raw = value?.array else { return nil }
  return (0..<length).map { index in
    guard index < raw.count, case .number(let step) = raw[index] else { return .off }
    return step == 1 ? .on : step == 2 ? .accent : .off
  }
}

private func bassLine(_ value: JSONValue?, length: Int) -> [BassStep]? {
  guard let raw = value?.array else { return nil }
  return (0..<length).map { index in
    guard index < raw.count, let step = raw[index].object else { return .rest }
    return BassStep(
      // Clamped to the two octaves the grid can show: a note outside them would be unreachable.
      note: step["note"]?.finite.map { max(0, min(24, $0)) },
      accent: step["accent"]?.bool == true, slide: step["slide"]?.bool == true,
      gate: step["gate"]?.bool)
  }
}

private func pattern(_ value: JSONValue, index: Int) -> Pattern? {
  guard let value = value.object else { return nil }

  var id = "pattern-\(index)"
  if let given = value["id"]?.string, !given.isEmpty { id = given }
  var name = id
  if let given = value["name"]?.string, !given.isEmpty { name = given }
  let length = Int(jsRound(clamp(value["length"], 1, 64, 16)))
  var pattern = Pattern(id: id, name: name, length: length)

  for (voiceId, track) in value["tracks"]?.object?.members ?? [] {
    if let parsed = steps(track, length: length) { pattern.tracks[voiceId] = parsed }
  }
  for (voiceId, raw) in value["trackLengths"]?.object?.members ?? [] {
    guard !voiceId.isEmpty, let raw = raw.finite else { continue }
    let parsed = max(1, min(length, Int(jsRound(raw))))
    // A lane as long as its pattern is the default, and stays unwritten.
    if parsed < length { pattern.trackLengths[voiceId] = parsed }
  }
  for (voiceId, line) in value["bass"]?.object?.members ?? [] {
    if let parsed = bassLine(line, length: length) { pattern.bass[voiceId] = parsed }
  }
  for (voiceId, marks) in value["flams"]?.object?.members ?? [] {
    guard let marks = marks.array else { continue }
    pattern.flams[voiceId] = (0..<length).map { $0 < marks.count && marks[$0].bool == true }
  }
  pattern.pcf = steps(value["pcf"], length: length)
  return pattern
}

/// Voice ids are not checked against any registry. One this build does not know may belong to a
/// machine added later, and deleting somebody's settings because they opened an older build is
/// not a repair.
private func kit(_ value: JSONValue?) -> Kit {
  let source = value?.object
  var kit = Kit()
  for (voiceId, value) in source?["params"]?.object?.members ?? [] { kit.params[voiceId] = knobs(value) }
  for (voiceId, value) in source?["bass"]?.object?.members ?? [] { kit.bass[voiceId] = knobs(value) }
  for (voiceId, value) in source?["sends"]?.object?.members ?? [] { kit.sends[voiceId] = knobs(value) }
  for (voiceId, value) in source?["swing"]?.object?.members ?? [] {
    // 0.5 is the centre — no offset from the song's swing.
    kit.swing[voiceId] = clamp(value, 0, 1, 0.5)
  }
  if let flam = source?["flam"]?.finite { kit.flam = max(0, min(1, flam)) }
  return kit
}

private func automation(_ value: JSONValue?) -> [AutomationLane] {
  var lanes: [AutomationLane] = []
  var seen = Set<String>()
  // Generous for authored music, and enough to stop an imported file turning one lookup per step
  // into unbounded work.
  for rawLane in (value?.array ?? []).prefix(256) {
    guard let rawLane = rawLane.object, let rawTarget = rawLane["target"]?.string,
      !jsTrim(rawTarget).isEmpty, let rawPoints = rawLane["points"]?.array
    else { continue }
    let target = jsPrefix(rawTarget, 160)
    if seen.contains(target) { continue }

    let knobLike = ["song/", "voice/", "bass/", "swing/", "send/", "fx/"].contains { target.hasPrefix($0) }
    var points: [AutomationPoint] = []
    for rawPoint in rawPoints.prefix(4096) {
      guard let rawPoint = rawPoint.object, let value = rawPoint["value"]?.finite else { continue }
      let point = AutomationPoint(
        bar: Int(jsRound(clamp(rawPoint["bar"], 0, 4095, 0))),
        index: Int(jsRound(clamp(rawPoint["index"], 0, 63, 0))),
        value: target == AutomationTarget.bpm
          ? max(20, min(300, value))
          : knobLike ? max(0, min(1, value)) : max(-1_000_000, min(1_000_000, value)))
      // A later point at the same position replaces the earlier one.
      if let existing = points.firstIndex(where: { $0.bar == point.bar && $0.index == point.index }) {
        points[existing] = point
      } else {
        points.append(point)
      }
    }
    if points.isEmpty { continue }
    points.sort { ($0.bar, $0.index) < ($1.bar, $1.index) }
    seen.insert(target)
    lanes.append(
      AutomationLane(
        target: target, interpolation: rawLane["interpolation"]?.string == "hold" ? .hold : .linear,
        points: points))
  }
  return lanes
}

// MARK: - Writing

/// In the order the reference's decoder builds a song, which is the order it is written in.
private func json(_ song: Song) -> JSONValue {
  var out = JSONObject()
  out["bpm"] = .number(song.bpm)
  out["swing"] = .number(song.swing)
  out["patterns"] = .array(song.patterns.map(json))
  out["chain"] = .array(
    song.chain.map { step in
      var out = JSONObject()
      out["pattern"] = .string(step.pattern)
      out["repeat"] = .number(Double(step.repeat))
      if !step.clips.isEmpty {
        var clips = JSONObject()
        for slot in ClipSlot.allCases {
          if let id = step.clips[slot] { clips[slot.name] = .string(id) }
        }
        out["clips"] = .object(clips)
      }
      return .object(out)
    })
  out["kit"] = json(song.kit)
  out["fx"] = json(song.fx)
  if !song.automation.isEmpty {
    out["automation"] = .array(
      song.automation.map { lane in
        var out = JSONObject()
        out["target"] = .string(lane.target)
        out["interpolation"] = .string(lane.interpolation == .hold ? "hold" : "linear")
        out["points"] = .array(
          lane.points.map { point in
            var out = JSONObject()
            out["bar"] = .number(Double(point.bar))
            out["index"] = .number(Double(point.index))
            out["value"] = .number(point.value)
            return .object(out)
          })
        return .object(out)
      })
  }
  if let visual = song.visual { out["visual"] = .string(visual) }
  return .object(out)
}

private func json(_ pattern: Pattern) -> JSONValue {
  var out = JSONObject()
  out["id"] = .string(pattern.id)
  out["name"] = .string(pattern.name)
  out["length"] = .number(Double(pattern.length))
  out["tracks"] = json(pattern.tracks) { .array($0.map { .number(Double($0.rawValue)) }) }
  if !pattern.trackLengths.isEmpty {
    out["trackLengths"] = json(pattern.trackLengths) { .number(Double($0)) }
  }
  out["bass"] = json(pattern.bass) { line in
    .array(
      line.map { step in
        var out = JSONObject()
        out["note"] = step.note.map(JSONValue.number) ?? .null
        out["accent"] = .bool(step.accent)
        out["slide"] = .bool(step.slide)
        if let gate = step.gate { out["gate"] = .bool(gate) }
        return .object(out)
      })
  }
  if !pattern.flams.isEmpty { out["flams"] = json(pattern.flams) { .array($0.map(JSONValue.bool)) } }
  if let pcf = pattern.pcf { out["pcf"] = .array(pcf.map { .number(Double($0.rawValue)) }) }
  return .object(out)
}

private func json(_ kit: Kit) -> JSONValue {
  var out = JSONObject()
  out["params"] = json(kit.params) { json($0) }
  out["bass"] = json(kit.bass) { json($0) }
  out["sends"] = json(kit.sends) { json($0) }
  out["swing"] = json(kit.swing) { .number($0) }
  if let flam = kit.flam { out["flam"] = .number(flam) }
  return .object(out)
}

private func json<Knobs: KnobSet>(_ knobs: Knobs) -> JSONValue {
  var out = JSONObject()
  for knob in 0..<Knobs.names.count { out[Knobs.names[knob]] = .number(knobs[knob]) }
  return .object(out)
}

private func json<Value>(_ map: OrderedMap<Value>, _ value: (Value) -> JSONValue) -> JSONValue {
  var out = JSONObject()
  for (key, member) in zip(map.keys, map.values) { out[key] = value(member) }
  return .object(out)
}

// MARK: - JavaScript's arithmetic and strings, where they differ from Swift's

/// `Math.round`: halves go towards positive infinity, so 2.5 is 3 and -2.5 is -2. Swift's
/// `rounded()` sends halves away from zero.
func jsRound(_ value: Double) -> Double {
  let floor = value.rounded(.down)
  return value - floor >= 0.5 ? floor + 1 : floor
}

/// `String.prototype.trim`: Unicode white space, line terminators, and the byte order mark.
func jsTrim(_ string: String) -> String {
  func blank(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || scalar.value == 0xFEFF
  }
  let scalars = string.unicodeScalars
  guard let first = scalars.firstIndex(where: { !blank($0) }),
    let last = scalars.lastIndex(where: { !blank($0) })
  else { return "" }
  return String(scalars[first...last])
}

/// `slice(0, count)`, which counts UTF-16 code units rather than characters.
func jsPrefix(_ string: String, _ count: Int) -> String {
  string.utf16.count <= count ? string : String(decoding: Array(string.utf16.prefix(count)), as: UTF16.self)
}
