// Parameters over the song timeline. A port of `driftbox/packages/engine/src/automation.ts`: reading a
// lane at a step, and writing a point into one, as recording does.

/// Stable target names. Built here so nothing else invents a second spelling.
public enum AutomationTarget {
  public static let bpm = "song/bpm"
  public static let swing = "song/swing"
  public static func voice(_ voiceId: String, _ knob: String) -> String { "voice/\(voiceId)/\(knob)" }
  public static func bass(_ voiceId: String, _ knob: String) -> String { "bass/\(voiceId)/\(knob)" }
  public static func voiceSwing(_ voiceId: String) -> String { "swing/\(voiceId)" }
  public static func send(_ voiceId: String, _ knob: String) -> String { "send/\(voiceId)/\(knob)" }
  public static func fx(_ knob: String) -> String { "fx/\(knob)" }
}

extension Song {
  func lane(_ target: String) -> AutomationLane? {
    automation.first { $0.target == target }
  }

  /// Steps between two positions, walking the real bar lengths — a polymetric song has bars of
  /// different sizes, and an interpolation that assumed sixteen would bend in the wrong place.
  func stepDistance(fromBar: Int, fromIndex: Int, toBar: Int, toIndex: Int) -> Int {
    let start = max(0, min(barLength(forBar: fromBar) - 1, fromIndex))
    let end = max(0, min(barLength(forBar: toBar) - 1, toIndex))
    if fromBar == toBar { return end - start }
    var distance = barLength(forBar: fromBar) - start
    var bar = fromBar + 1
    while bar < toBar {
      distance += barLength(forBar: bar)
      bar += 1
    }
    return distance + end
  }

  /// A lane's value at a position. Before its first point the underlying parameter stays in
  /// charge; after its last, the last value is held.
  public func automationValue(_ target: String, bar: Int, index: Int, fallback: Double) -> Double {
    guard let lane = lane(target), !lane.points.isEmpty else { return fallback }

    var previous: AutomationPoint?
    for point in lane.points {
      if point.bar > bar || (point.bar == bar && point.index > index) {
        guard let previous else { return fallback }
        if lane.interpolation == .hold { return previous.value }
        let span = stepDistance(
          fromBar: previous.bar, fromIndex: previous.index, toBar: point.bar, toIndex: point.index)
        if span <= 0 { return point.value }
        let elapsed = stepDistance(
          fromBar: previous.bar, fromIndex: previous.index, toBar: bar, toIndex: index)
        let amount = Double(elapsed) / Double(span)
        return previous.value + (point.value - previous.value) * amount
      }
      previous = point
    }
    return previous?.value ?? fallback
  }

  func automated<Knobs: KnobSet>(
    _ base: Knobs, bar: Int, index: Int, target: (String) -> String
  ) -> Knobs {
    var result = base
    for knob in 0..<Knobs.names.count {
      let value = automationValue(target(Knobs.names[knob]), bar: bar, index: index, fallback: base[knob])
      result[knob] = clamp(value, 0, 1)
    }
    return result
  }

  public func voiceParams(_ voiceId: String, bar: Int, index: Int) -> VoiceParams {
    automated(kit.params[voiceId] ?? .defaults, bar: bar, index: index) {
      AutomationTarget.voice(voiceId, $0)
    }
  }

  public func bassParams(_ voiceId: String, bar: Int, index: Int) -> BassParams {
    automated(kit.bass[voiceId] ?? .defaults, bar: bar, index: index) {
      AutomationTarget.bass(voiceId, $0)
    }
  }

  public func sendLevels(_ voiceId: String, bar: Int, index: Int) -> SendLevels {
    automated(kit.sends[voiceId] ?? .defaults, bar: bar, index: index) {
      AutomationTarget.send(voiceId, $0)
    }
  }

  public func fxParams(bar: Int, index: Int) -> FxParams {
    automated(fx, bar: bar, index: index) { AutomationTarget.fx($0) }
  }

  public func bpm(bar: Int, index: Int) -> Double {
    clamp(automationValue(AutomationTarget.bpm, bar: bar, index: index, fallback: bpm), 20, 300)
  }

  /// How much a voice swings: the song's swing, shifted by that voice's offset. A voice with no
  /// offset and no lane of its own simply swings with the song.
  public func swing(_ voiceId: String, bar: Int, index: Int) -> Double {
    let songSwing = clamp(
      automationValue(AutomationTarget.swing, bar: bar, index: index, fallback: swing), 0, 1)
    let baseOffset = kit.swing[voiceId]
    let target = AutomationTarget.voiceSwing(voiceId)
    let offset = clamp(
      automationValue(target, bar: bar, index: index, fallback: baseOffset ?? 0.5), 0, 1)
    if baseOffset == nil && lane(target) == nil { return songSwing }
    return clamp(songSwing + (offset - 0.5) * 2, 0, 1)
  }
}

extension Song {
  /// The song with `value` at `bar` and step `index` of `target`'s lane, the lane made on first use
  /// with `interpolation`, and a point already there replaced: the reference's `setAutomationPoint`,
  /// which records as a control turns. A blank target or a value that is not a number changes
  /// nothing.
  public func settingAutomationPoint(
    _ target: String, bar: Int, index: Int, value: Double, interpolation: AutomationInterpolation = .linear
  ) -> Song {
    guard !target.allSatisfy({ $0.isWhitespace }), value.isFinite else { return self }
    let pointBar = max(0, bar)
    let point = AutomationPoint(
      bar: pointBar, index: max(0, min(barLength(forBar: pointBar) - 1, index)), value: value)
    let existing = automation.firstIndex { $0.target == target }
    var points = (existing.map { automation[$0].points } ?? []).filter {
      $0.bar != point.bar || $0.index != point.index
    }
    points.append(point)
    points.sort { ($0.bar, $0.index) < ($1.bar, $1.index) }
    let lane = AutomationLane(target: target, interpolation: interpolation, points: points)
    var song = self
    if let existing { song.automation[existing] = lane } else { song.automation.append(lane) }
    return song
  }

  /// The song without `target`'s lane: the reference's `clearAutomationLane`.
  public func clearingAutomationLane(_ target: String) -> Song {
    var song = self
    song.automation.removeAll { $0.target == target }
    return song
  }
}
