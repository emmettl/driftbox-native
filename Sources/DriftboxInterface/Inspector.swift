import DriftboxEngine
import DriftboxSeq

extension Layout {
  public static let inspectorWidth: Float = 280

  /// A knob on a panel: the dial, and the whole of its place there, which is what a press hits.
  public struct Knob {
    public var target: KnobTarget
    public var dial: Rect
    public var cell: Rect
  }

  /// A panel down the right, as the Mac's inspector has it: the selected voice's, with which machine
  /// and which voice at its head, its knobs three to a row, then its sends and its swing set apart
  /// below; or the song's effects, in their groups.
  public struct Inspector {
    /// The voice it is for, or nil for the effects.
    public var voice: String?
    public var frame: Rect
    /// `TR-808`, `TR-909`, `TB-303` or `MASTER`.
    public var machine: String
    public var title: String
    public var chips: [Chip]
    public var knobs: [Knob]
    /// Where a line sets the last knobs apart, if one does.
    public var divider: Float?
    /// Small captions: what a group of knobs is.
    public var labels: [Label] = []

    /// The same panel with its top at `top`: on a phone, where it is a sheet at the foot of the
    /// screen rather than a column down the right.
    func moved(to top: Float) -> Inspector {
      let dy = top - frame.y
      func move(_ rect: Rect) -> Rect { Rect(rect.x, rect.y + dy, rect.width, rect.height) }
      var moved = self
      moved.frame = move(frame)
      moved.chips = chips.map {
        Chip(frame: move($0.frame), label: $0.label, action: $0.action, isOn: $0.isOn)
      }
      moved.knobs = knobs.map { Knob(target: $0.target, dial: move($0.dial), cell: move($0.cell)) }
      moved.divider = divider.map { $0 + dy }
      moved.labels = labels.map { Label(text: $0.text, x: $0.x, y: $0.y + dy) }
      return moved
    }
  }

  public struct Label {
    public var text: String
    public var x: Float
    /// Its baseline.
    public var y: Float
  }

  static let padding: Float = 14
  static let knobCell: Float = 70

  /// The panel for `id`, a drum voice or a 303, at the top right under the transport, `width`
  /// across; nil for anything else.
  static func inspector(for id: String, top: Float, right: Float, width: Float = inspectorWidth) -> Inspector?
  {
    let machine: String
    let title: String
    let targets: [KnobTarget]
    if let voice = allVoices.first(where: { $0.id == id }) {
      machine = voice.machine == .tr808 ? "TR-808" : "TR-909"
      title = voice.name
      targets = KnobSpec.voice.indices.map { .voice(id, $0) }
    } else if id == "303.a" || id == "303.b" {
      machine = "TB-303"
      title = id == "303.a" ? "303 A" : "303 B"
      targets = KnobSpec.bass.indices.map { .bass(id, $0) }
    } else {
      return nil
    }

    let x = right - width
    let inner = x + padding
    let innerWidth = width - padding * 2
    var y = top + padding

    // The head: what it is on the left, and on the right what can be done with it.
    let close = Rect(inner + innerWidth - 26, y, 26, 24)
    var chips = [Chip(frame: close, label: "×", action: .close, isOn: false)]
    if machine == "TB-303" {
      for (index, line) in ["303.b", "303.a"].enumerated() {
        let frame = Rect(close.x - Float(index + 1) * 30, y, 26, 24)
        chips.append(
          Chip(frame: frame, label: line == "303.a" ? "A" : "B", action: .show(voice: line), isOn: line == id)
        )
      }
    } else {
      chips.append(
        Chip(frame: Rect(close.x - 6 - 62, y, 62, 24), label: "HIT IT", action: .hit(voice: id), isOn: false))
    }
    y += 34 + 12

    var knobs: [Knob] = []
    let column = innerWidth / 3
    for (index, target) in targets.enumerated() {
      let cell = Rect(
        inner + Float(index % 3) * column, y + Float(index / 3) * (knobCell + 10), column, knobCell)
      knobs.append(Knob(target: target, dial: Rect(cell.x + (column - 40) / 2, cell.y, 40, 40), cell: cell))
    }
    let rows = (targets.count + 2) / 3
    y += Float(rows) * knobCell + Float(rows - 1) * 10 + 12

    // The sends and the swing: where the voice goes and when, rather than how it sounds.
    let divider = y
    y += 9
    let sends: [KnobTarget] = [.send(id, 0), .send(id, 1), .swing(id)]
    // Spread across a wider panel, a phone's sheet, where a finger wants the room.
    let sendWidth: Float = width > inspectorWidth ? (innerWidth - 30) / 3 : 64
    for (index, target) in sends.enumerated() {
      let cell = Rect(inner + 30 + Float(index) * sendWidth, y, sendWidth, 62)
      knobs.append(
        Knob(target: target, dial: Rect(cell.x + (sendWidth - 32) / 2, cell.y, 32, 32), cell: cell))
    }
    y += 62 + padding
    return Inspector(
      voice: id, frame: Rect(x, top, width, y - top), machine: machine, title: title, chips: chips,
      knobs: knobs, divider: divider, labels: [Label(text: "OUT", x: inner, y: divider + 29)])
  }
}

extension Layout {
  /// The song's effects, as the Mac's panel groups them: the inserts, the pattern-controlled
  /// filter, the delay and the reverb, a row of knobs each under its name.
  static func effects(top: Float, right: Float, width: Float = inspectorWidth) -> Inspector {
    let x = right - width
    let inner = x + padding
    let innerWidth = width - padding * 2
    var y = top + padding
    let close = Chip(
      frame: Rect(inner + innerWidth - 26, y, 26, 24), label: "×", action: .effects, isOn: false)
    y += 34 + 8

    var knobs: [Knob] = []
    var labels: [Label] = []
    for group in KnobSpec.fxGroups {
      labels.append(Label(text: group.name.uppercased(), x: inner, y: y + 9))
      y += 16
      // The filter's five in a row of their own, smaller; the rest three to a row, as on a voice.
      let columns: Float = group.knobs.count > 3 ? 5 : 3
      let diameter: Float = group.knobs.count > 3 ? 32 : 36
      let column = innerWidth / columns
      for (index, knob) in group.knobs.enumerated() {
        let cell = Rect(inner + Float(index) * column, y, column, diameter + 28)
        knobs.append(
          Knob(
            target: .fx(knob), dial: Rect(cell.x + (column - diameter) / 2, y, diameter, diameter), cell: cell
          ))
      }
      y += diameter + 28 + 8
    }
    y += padding - 8
    return Inspector(
      voice: nil, frame: Rect(x, top, width, y - top), machine: "MASTER", title: "Effects",
      chips: [close], knobs: knobs, divider: nil, labels: labels)
  }
}
