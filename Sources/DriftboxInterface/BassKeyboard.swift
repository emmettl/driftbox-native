import DriftboxSeq

/// On a phone, how a 303 step's note is set: as the machine itself is programmed, a step at a time
/// on a keyboard. One octave and the C above it, at a finger's size, with the chips for everything
/// else a step has: the one before and after, a rest, the octave, accent and slide.
///
/// It sits above the grid, over the scene, in room the layout leaves it by making the grid shorter,
/// so the step it is setting stays in sight. It is arithmetic, as `Layout` is: the drawing and the
/// finger read the same one.
public struct BassKeyboard {
  public struct Key {
    public var frame: Rect
    /// Semitones above C1, as a 303 step keeps its note.
    public var note: Int
    public var black: Bool
  }

  public static let height: Float = 172
  /// White keys across, C to C.
  static let whites = [0, 2, 4, 5, 7, 9, 11, 12]
  /// The black keys, and the white key each sits after.
  static let blacks: [(note: Int, after: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]
  static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

  public var frame: Rect
  public var voice: String
  public var index: Int
  public var octave: Int
  public var step: BassStep
  /// Where the step's name and note are written.
  public var title: Rect
  public var chips: [Layout.Chip]
  public var keys: [Key]

  /// The keyboard for `voice`'s `index`th step in the pattern `layout` shows, `octave` up, or nil
  /// where there is no such line or step.
  public init?(layout: Layout, voice: String, index: Int, octave: Int) {
    guard let pattern = layout.pattern, pattern.bass[voice] != nil, index >= 0, index < pattern.length,
      let strip = layout.strip
    else { return nil }
    self.voice = voice
    self.index = index
    self.octave = min(1, max(0, octave))
    step = pattern.bassStep(voice, at: index)
    let width = layout.bar.width
    // Over the scene above the grid, in the room the layout leaves it there.
    let above = (layout.grid?.y ?? layout.size.y) - Layout.margin - Self.height
    frame = Rect(layout.bar.x, max(strip.maxY + Layout.margin, above), width, Self.height)

    let inner = Rect(frame.x + 10, frame.y + 10, width - 20, Self.height - 20)
    let id = pattern.id
    let last = pattern.length - 1
    let row: Float = 32
    title = Rect(inner.x, inner.y, 120, row)
    var x = inner.maxX
    func chip(_ label: String, _ width: Float, _ action: Action, on: Bool = false, y: Float) -> Layout.Chip {
      x -= width
      defer { x -= 6 }
      return Layout.Chip(frame: Rect(x, y, width, row), label: label, action: action, isOn: on)
    }
    // Across the top: done, the next step and the one before, and a rest.
    chips = [
      chip("×", 36, .bassStep(voice: voice, index: nil), y: inner.y),
      chip("▶", 40, .bassStep(voice: voice, index: index == last ? 0 : index + 1), y: inner.y),
      chip("◀", 40, .bassStep(voice: voice, index: index == 0 ? last : index - 1), y: inner.y),
      chip("REST", 56, .bassGate(pattern: id, voice: voice, index: index), on: !step.sounds, y: inner.y),
    ]
    // Along the bottom: the octave, accent and slide.
    x = inner.maxX
    let bottom = inner.maxY - row
    chips += [
      chip("SLIDE", 64, .bassSlide(pattern: id, voice: voice, index: index), on: step.slide, y: bottom),
      chip("ACCENT", 72, .bassAccent(pattern: id, voice: voice, index: index), on: step.accent, y: bottom),
    ]
    let octaveChip = Layout.Chip(
      frame: Rect(inner.x, bottom, 96, row), label: self.octave == 0 ? "C1–C2" : "C2–C3",
      action: .octave(1 - self.octave), isOn: false)
    chips.append(octaveChip)

    // The keys between the rows.
    let keysTop = inner.y + row + 8
    let keysHeight = bottom - 8 - keysTop
    let white = inner.width / Float(Self.whites.count)
    let base = self.octave * 12
    keys = Self.whites.enumerated().map { column, offset in
      Key(
        frame: Rect(inner.x + Float(column) * white, keysTop, white - 3, keysHeight), note: base + offset,
        black: false)
    }
    keys += Self.blacks.map { note, after in
      Key(
        frame: Rect(
          inner.x + Float(after + 1) * white - white * 0.3 - 1.5, keysTop, white * 0.6, keysHeight * 0.6),
        note: base + note, black: true)
    }
  }

  /// What a finger at `point` does: a black key before the white one under it, since it sits on top.
  public func action(at point: SIMD2<Float>, pattern: String) -> Action? {
    if let chip = chips.first(where: { $0.frame.contains(point) }) { return chip.action }
    let key =
      keys.last { $0.black && $0.frame.contains(point) }
      ?? keys.first { !$0.black && $0.frame.contains(point) }
    return key.map { .note(pattern: pattern, voice: voice, index: index, note: $0.note) }
  }

  /// A 303 note by name: 0 is C1.
  public static func name(_ note: Int) -> String { "\(names[note % 12])\(note / 12 + 1)" }
}
