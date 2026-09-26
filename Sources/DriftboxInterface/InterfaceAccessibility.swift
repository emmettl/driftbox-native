import DriftboxSeq
import DriftboxShell

/// The groovebox's controls as a screen reader is told them: what is on the screen, by the names a
/// person would give it — Play, the tempo, a lane's steps, the knobs of the voice showing — each with
/// what it is set to, and what a screen reader asks of one done as a hand would do it.
///
/// Each control's id lasts from one frame to the next, so a screen reader keeps its place: the
/// transport's by what it does, a step by its lane and number, a knob by what it turns.
extension Interface {
  /// What is on screen, as the window hands it to the platform's accessibility.
  public var accessibility: AccessibilityNode { described().node }

  /// What a screen reader asked, done as a hand would do it; false for a control there is not.
  @discardableResult
  public func perform(_ asked: AccessibilityAction) -> Bool {
    let id: String
    switch asked {
    case .press(let control), .set(let control, _), .increment(let control), .decrement(let control):
      id = control
    }
    guard let handle = described().handlers[id] else { return false }
    handle(asked)
    return true
  }

  typealias Handler = (AccessibilityAction) -> Void

  /// The tree, and what each control does when asked.
  func described() -> (node: AccessibilityNode, handlers: [String: Handler]) {
    var handlers: [String: Handler] = [:]
    let layout = layout
    func frame(_ rect: Rect) -> SIMD4<Float> { SIMD4(rect.x, rect.y, rect.width, rect.height) }
    /// A control pressed as it is clicked.
    func pressed(_ action: Action) -> Handler {
      { [weak self] asked in if case .press = asked { self?.perform(action) } }
    }

    guard isShowing else {
      return (
        AccessibilityNode(
          id: "window", role: .group, name: "",
          children: [
            AccessibilityNode(
              id: "hidden", role: .text, name: "The controls are put away", value: "Tab brings them back")
          ]), [:]
      )
    }

    var children: [AccessibilityNode] = []

    // The bar: the transport, the song's name and where it has got to, and the tempo and swing.
    var bar: [AccessibilityNode] = []
    for chip in layout.chips {
      guard let (id, name, role) = Self.transport(chip.action) else { continue }
      let lanes = chip.label.hasPrefix("AUTO ") ? "\(chip.label.dropFirst(5)) lanes" : nil
      bar.append(
        AccessibilityNode(
          id: id, role: role, name: name, value: lanes, isOn: role == .toggle ? chip.isOn : nil,
          frame: frame(chip.frame)))
      handlers[id] = pressed(chip.action)
    }
    if let songChip = layout.songChip {
      bar.append(
        AccessibilityNode(
          id: "song.menu", role: .button, name: "Song", value: session.documentName,
          frame: frame(songChip.frame)))
      handlers["song.menu"] = pressed(songChip.action)
    }
    bar.append(
      AccessibilityNode(
        id: "song.title", role: .text, name: "Song",
        value: session.song == nil ? "No song" : session.documentName,
        frame: frame(layout.title)))
    if session.song != nil {
      let bar1 = (session.position?.bar ?? 0) + 1
      let step1 = (session.position?.step ?? 0) + 1
      let place = "Bar \(bar1), step \(step1) of \(layout.pattern?.length ?? 16)"
      bar.append(
        AccessibilityNode(
          id: "song.position", role: .text, name: session.isPlaying ? "Playing" : "Stopped", value: place,
          frame: frame(layout.readout)))
    }
    if let song = session.song {
      for number in layout.numbers {
        let id = "number.\(Self.key(number.target))"
        let name = number.target == .tempo ? "Tempo" : "Swing"
        bar.append(knob(number.target, id: id, name: name, song: song, frame: number.cell))
        handlers[id] = turned(number.target)
      }
    }
    children.append(
      AccessibilityNode(id: "bar", role: .group, name: "Transport", frame: frame(layout.bar), children: bar))

    // The song strip: each section plays from where it starts.
    if !layout.sections.isEmpty {
      let playing = session.position?.bar
      let sections = layout.sections.map { section -> AccessibilityNode in
        let id = "section.\(section.index)"
        handlers[id] = pressed(.seek(bar: section.start))
        let here = playing.map { $0 >= section.start && $0 < section.start + section.bars } ?? false
        return AccessibilityNode(
          id: id, role: .button, name: "\(section.name), \(section.bars) bar\(section.bars == 1 ? "" : "s")",
          value: here ? "playing" : nil, frame: frame(section.frame))
      }
      let strip = layout.sectionsFrame ?? layout.strip ?? layout.bar
      children.append(
        AccessibilityNode(
          id: "sections", role: .group, name: "Song sections", frame: frame(strip), children: sections))
    }

    // The patterns, and the pages of steps.
    var patterns: [AccessibilityNode] = []
    for chip in layout.patternChips + layout.pageChips {
      let (id, name, role): (String, String, AccessibilityNode.Role)
      switch chip.action {
      case .follow: (id, name, role) = ("pattern.follow", "Follow the pattern playing", .toggle)
      case .addPattern: (id, name, role) = ("pattern.add", "Add a pattern", .button)
      case .showPattern(let pattern):
        (id, name, role) = ("pattern.\(pattern)", "Pattern \(chip.label)", .toggle)
      case .page(let page): (id, name, role) = ("page.\(page)", "Steps \(chip.label)", .toggle)
      default: continue
      }
      patterns.append(
        AccessibilityNode(
          id: id, role: role, name: name, isOn: role == .toggle ? chip.isOn : nil, frame: frame(chip.frame)))
      handlers[id] = pressed(chip.action)
    }
    if !patterns.isEmpty {
      children.append(AccessibilityNode(id: "patterns", role: .group, name: "Patterns", children: patterns))
    }

    // The grid: each lane's steps, the filter's, and each 303 line's.
    if let pattern = layout.pattern, let metrics = layout.metrics {
      for lane in layout.lanes {
        let voice = lane.voice.id
        let prefix = "lane.\(voice)"
        var steps: [AccessibilityNode] = [
          AccessibilityNode(
            id: "\(prefix).select", role: .button, name: "Show \(lane.voice.name)'s knobs",
            frame: frame(lane.header))
        ]
        handlers["\(prefix).select"] = pressed(.select(voice: voice))
        for index in 0..<pattern.trackLength(voice) {
          let value = pattern.step(voice, at: index)
          let id = "\(prefix).step.\(index + 1)"
          steps.append(
            AccessibilityNode(
              id: id, role: .toggle, name: "Step \(index + 1)", value: Self.words(value), isOn: value != .off,
              frame: frame(layout.step(index, in: lane.frame))))
          handlers[id] = pressed(.step(pattern: pattern.id, voice: voice, index: index))
        }
        children.append(
          AccessibilityNode(
            id: prefix, role: .group, name: lane.voice.name, frame: frame(lane.frame), children: steps))
      }
      if let filterLane = layout.filterLane {
        let steps = (0..<pattern.length).map { index -> AccessibilityNode in
          let value = pattern.pcf(at: index)
          let id = "filter.step.\(index + 1)"
          handlers[id] = pressed(.filterStep(pattern: pattern.id, index: index))
          return AccessibilityNode(
            id: id, role: .toggle, name: "Step \(index + 1)", value: Self.words(value), isOn: value != .off,
            frame: frame(layout.step(index, in: filterLane)))
        }
        children.append(
          AccessibilityNode(
            id: "filter", role: .group, name: "Pattern-controlled filter", frame: frame(filterLane),
            children: steps))
      }
      for line in layout.bassLines {
        children.append(
          bassLine(line, pattern: pattern, metrics: metrics, layout: layout, handlers: &handlers))
      }
    }

    // The knobs of the voice showing, or the song's effects.
    if let inspector = layout.inspector, let song = session.song {
      var panel: [AccessibilityNode] = []
      for chip in inspector.chips {
        let (id, name): (String, String)
        switch chip.action {
        case .close: (id, name) = ("inspector.close", "Put the knobs away")
        case .hit(let voice): (id, name) = ("inspector.hit.\(voice)", "Hit it")
        case .show(let voice): (id, name) = ("inspector.show.\(voice)", "303 \(chip.label)")
        default: continue
        }
        panel.append(
          AccessibilityNode(
            id: id, role: chip.isOn ? .toggle : .button, name: name, isOn: chip.isOn ? true : nil,
            frame: frame(chip.frame)))
        handlers[id] = pressed(chip.action)
      }
      for knob in inspector.knobs {
        let id = "knob.\(Self.key(knob.target))"
        let name = "\(inspector.title) \(knob.target.spec.label.capitalized)"
        panel.append(self.knob(knob.target, id: id, name: name, song: song, frame: knob.cell))
        handlers[id] = turned(knob.target)
      }
      children.append(
        AccessibilityNode(
          id: "inspector", role: .group, name: "\(inspector.machine) \(inspector.title)",
          frame: frame(inspector.frame), children: panel))
    }

    return (AccessibilityNode(id: "window", role: .group, name: "", children: children), handlers)
  }

  // MARK: - Knobs

  /// A knob or a number as a slider: its range, where it is, and what that is in its own words.
  func knob(_ target: KnobTarget, id: String, name: String, song: Song, frame rect: Rect) -> AccessibilityNode
  {
    let value = target.value(in: song)
    let range = target.range
    // The numbers' units, which the bar shows by where they are.
    let units = target == .tempo ? " BPM" : target == .songSwing ? "%" : ""
    return AccessibilityNode(
      id: id, role: .slider, name: name, value: target.format(value, in: song) + units, range: range,
      current: value, step: Self.notch(target), frame: SIMD4(rect.x, rect.y, rect.width, rect.height))
  }

  /// How far a notch turns a knob: a whole number for the tempo and swing, a fiftieth of the way
  /// round for a knob.
  static func notch(_ target: KnobTarget) -> Double {
    target.isNumber ? 1 : (target.range.upperBound - target.range.lowerBound) / 50
  }

  /// A knob set or stepped, as one turn of it: heard, recorded where automation is armed, and one
  /// step of undo.
  func turned(_ target: KnobTarget) -> Handler {
    { [weak self] asked in
      guard let self, let song = session.song else { return }
      let range = target.range
      let now = target.value(in: song)
      let wanted: Double
      switch asked {
      case .set(_, let value): wanted = value
      case .increment: wanted = now + Self.notch(target)
      case .decrement: wanted = now - Self.notch(target)
      case .press: return
      }
      let clamped = min(range.upperBound, max(range.lowerBound, wanted))
      let next = target.isNumber ? clamped.rounded() : clamped
      guard next != now else { return }
      session.turn(
        target.editName, automating: target.automationTarget, value: target.songValue(next),
        interpolation: target.interpolation
      ) { target.set(next, in: &$0) }
      session.endTurn()
    }
  }

  // MARK: - The 303

  /// A 303 line: for each step its note, as a slider over the line's two octaves, and whether it
  /// sounds, is accented and slides, as toggles.
  func bassLine(
    _ line: Layout.BassLine, pattern: DriftboxSeq.Pattern, metrics: GridMetrics, layout: Layout,
    handlers: inout [String: Handler]
  ) -> AccessibilityNode {
    let voice = line.voice
    let prefix = "line.\(voice)"
    var steps: [AccessibilityNode] = [
      AccessibilityNode(
        id: "\(prefix).select", role: .button, name: "Show \(line.name)'s knobs",
        frame: SIMD4(line.header.x, line.header.y, line.header.width, line.header.height))
    ]
    handlers["\(prefix).select"] = { [weak self] asked in
      if case .press = asked { self?.perform(.select(voice: voice)) }
    }
    let lowest = BassMetrics.notes.min() ?? 0
    let highest = BassMetrics.notes.max() ?? 24
    for index in 0..<pattern.length {
      let step = pattern.bassStep(voice, at: index)
      let column = Float(layout.touch ? index - metrics.first : index)
      let cell = SIMD4(line.cells.x + column * metrics.stride, line.cells.y, metrics.cell, line.cells.height)
      let note = step.note.map { Int($0.rounded()) }
      let sounds = step.gate ?? (step.note != nil)
      let id = "\(prefix).step.\(index + 1)"
      steps.append(
        AccessibilityNode(
          id: id, role: .slider, name: "Step \(index + 1)",
          value: note.map { BassKeyboard.name($0) + (sounds ? "" : ", paused") } ?? "rest",
          range: Double(lowest)...Double(highest), current: Double(note ?? lowest), step: 1, frame: cell))
      handlers[id] = { [weak self] asked in
        guard let self else { return }
        let now = note ?? lowest
        let wanted: Int
        switch asked {
        case .set(_, let value): wanted = Int(value.rounded())
        case .increment: wanted = now + 1
        case .decrement: wanted = now - 1
        case .press: return
        }
        let next = min(highest, max(lowest, wanted))
        // The note set, as a click on its cell sets it; the same note again would pause it instead.
        guard next != note else { return }
        perform(.note(pattern: pattern.id, voice: voice, index: index, note: next))
      }
      let flags: [(String, String, Bool, Action)] = [
        ("sounds", "sounds", sounds, .bassGate(pattern: pattern.id, voice: voice, index: index)),
        ("accent", "accent", step.accent, .bassAccent(pattern: pattern.id, voice: voice, index: index)),
        ("slide", "slide", step.slide, .bassSlide(pattern: pattern.id, voice: voice, index: index)),
      ]
      for (flag, word, isOn, action) in flags {
        let flagId = "\(id).\(flag)"
        steps.append(
          AccessibilityNode(
            id: flagId, role: .toggle, name: "Step \(index + 1) \(word)", isOn: isOn, frame: cell))
        handlers[flagId] = { [weak self] asked in if case .press = asked { self?.perform(action) } }
      }
    }
    return AccessibilityNode(
      id: prefix, role: .group, name: line.name,
      frame: SIMD4(line.frame.x, line.frame.y, line.frame.width, line.frame.height), children: steps)
  }

  // MARK: - Words

  /// The transport's chips, by what they do: an id, a name and a role, or nil for one that is not
  /// the transport's.
  static func transport(_ action: Action) -> (String, String, AccessibilityNode.Role)? {
    switch action {
    case .toggle: ("transport.play", "Play", .toggle)
    case .start: ("transport.top", "Return to start", .button)
    case .perform: ("transport.perform", "Put the controls away", .button)
    case .automation: ("transport.automation", "Record automation", .toggle)
    case .effects: ("transport.effects", "Effects", .toggle)
    case .metronome: ("transport.metronome", "Metronome", .toggle)
    case .loop: ("transport.loop", "Loop this section", .toggle)
    default: nil
    }
  }

  static func words(_ value: StepValue) -> String {
    switch value {
    case .off: "off"
    case .on: "on"
    case .accent: "accent"
    }
  }

  /// A knob's lasting id: what it turns.
  static func key(_ target: KnobTarget) -> String {
    switch target {
    case .voice(let voice, let knob): "voice.\(voice).\(knob)"
    case .bass(let voice, let knob): "bass.\(voice).\(knob)"
    case .send(let voice, let knob): "send.\(voice).\(knob)"
    case .swing(let voice): "swing.\(voice)"
    case .fx(let knob): "fx.\(knob)"
    case .tempo: "tempo"
    case .songSwing: "swing"
    }
  }
}
