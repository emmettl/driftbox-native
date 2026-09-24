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

  /// The selected voice's panel, as the Mac's inspector has it: which machine and which voice at
  /// its head, its knobs three to a row, then its sends and its swing, set apart below.
  public struct Inspector {
    public var voice: String
    public var frame: Rect
    /// `TR-808`, `TR-909` or `TB-303`.
    public var machine: String
    public var title: String
    public var chips: [Chip]
    public var knobs: [Knob]
    /// Where the line over the sends is.
    public var sendsTop: Float
  }

  static let padding: Float = 14
  static let knobCell: Float = 70

  /// The panel for `id`, a drum voice or a 303, at the top right under the transport; nil for
  /// anything else.
  static func inspector(for id: String, top: Float, right: Float) -> Inspector? {
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

    let x = right - inspectorWidth
    let inner = x + padding
    let innerWidth = inspectorWidth - padding * 2
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
    let sendsTop = y
    y += 9
    let sends: [KnobTarget] = [.send(id, 0), .send(id, 1), .swing(id)]
    for (index, target) in sends.enumerated() {
      let cell = Rect(inner + 30 + Float(index) * 64, y, 64, 62)
      knobs.append(Knob(target: target, dial: Rect(cell.x + 16, cell.y, 32, 32), cell: cell))
    }
    y += 62 + padding
    return Inspector(
      voice: id, frame: Rect(x, top, inspectorWidth, y - top), machine: machine, title: title, chips: chips,
      knobs: knobs, sendsTop: sendsTop)
  }
}
