import DriftboxCanvas
import DriftboxHelp
import DriftboxShell
import DriftboxText

/// A page of help drawn over a screen, for the platforms whose screens are drawn: a panel with its
/// title and a way to close it, and under them the page's parts, wrapped to its width, that scroll
/// when there are more of them than it has room for. A wheel or a finger scrolls it; a press on
/// its cross, or anywhere off it, and Escape close it.
@MainActor
public final class HelpSheet {
  public let trail: String
  public let title: String
  public let parts: [HelpPart]
  /// How far down it is scrolled.
  public private(set) var scroll: Float = 0
  /// How tall its words were when last laid out, which is how far down it can go.
  public private(set) var contentHeight: Float = 0
  private var laidOut: (width: Float, lines: [Line])?
  /// A press on it, and whether it has moved far enough to be a scroll.
  private var press: (pointer: Int, from: SIMD2<Float>, last: SIMD2<Float>, moved: Bool)?

  public init(trail: String, title: String, parts: [HelpPart]) {
    self.trail = trail
    self.title = title
    self.parts = parts
  }

  // MARK: - Where it is

  /// The panel: as wide as reading wants, and the height of the window, less a margin.
  public static func frame(in size: SIMD2<Float>) -> Rect {
    let margin: Float = size.x < 500 ? 10 : 28
    let width = min(size.x - margin * 2, 620)
    return Rect((size.x - width) / 2, margin, width, max(0, size.y - margin * 2))
  }

  public static func close(in frame: Rect) -> Rect { Rect(frame.maxX - 42, frame.y + 10, 32, 32) }

  /// Where the words go, under the title.
  public static func body(in frame: Rect) -> Rect {
    Rect(frame.x + 20, frame.y + 70, max(0, frame.width - 40), max(0, frame.height - 82))
  }

  // MARK: - Input

  /// Take `event`, which a sheet over a screen always does; true once it should close.
  public func pointer(_ event: PointerEvent, in size: SIMD2<Float>) -> Bool {
    let frame = Self.frame(in: size)
    switch event.phase {
    case .began:
      press = (event.id, event.location, event.location, false)
    case .moved:
      guard var held = press, held.pointer == event.id else { return false }
      let moved = event.location - held.from
      if !held.moved, (moved * moved).sum() > 64 { held.moved = true }
      if held.moved { scroll(by: held.last.y - event.location.y, in: size) }
      held.last = event.location
      press = held
    case .ended:
      guard let held = press, held.pointer == event.id else { return false }
      press = nil
      if !held.moved {
        return Self.close(in: frame).contains(event.location) || !frame.contains(event.location)
      }
    case .cancelled:
      press = nil
    }
    return false
  }

  public func scroll(by amount: Float, in size: SIMD2<Float>) {
    let room = Self.body(in: Self.frame(in: size)).height
    scroll = min(max(0, scroll + amount), max(0, contentHeight - room))
  }

  /// True once a key closes it; every other key is its own too, so nothing behind it hears one.
  public func key(_ event: KeyEvent) -> Bool {
    event.isDown && event.key == .escape
  }

  // MARK: - Drawing

  /// A line of the page: its words, in what font and colour, how far in, and the step it takes.
  struct Line {
    var text: String
    var font: FontRequest
    var colour: Colour
    var x: Float
    var advance: Float
    /// A key, set on a chip.
    var chip = false
    /// A second piece on the same line, as a key's meaning beside it.
    var beside: (text: String, x: Float)?
  }

  static let text = Theme.mono(11)
  static let bold = Theme.mono(11, weight: 700)
  static let heading = Theme.mono(9, weight: 600)
  static let quiet = Theme.mono(10)
  static let lineHeight: Float = 16

  /// The page's lines at `width`, measured on `canvas`, wrapped where they would run past it.
  func layout(width: Float, on canvas: Canvas) -> [Line] {
    var lines: [Line] = []
    func wrap(_ words: String, font: FontRequest, colour: Colour, x: Float, width: Float) {
      canvas.font = font
      var line = ""
      for word in words.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if !line.isEmpty, canvas.measure(next) > width {
          lines.append(Line(text: line, font: font, colour: colour, x: x, advance: Self.lineHeight))
          line = String(word)
        } else {
          line = next
        }
      }
      lines.append(Line(text: line, font: font, colour: colour, x: x, advance: Self.lineHeight))
    }
    func gap(_ height: Float) {
      lines.append(Line(text: "", font: Self.text, colour: Theme.ink, x: 0, advance: height))
    }
    for (index, part) in parts.enumerated() {
      if index > 0 { gap(14) }
      lines.append(
        Line(text: part.heading.uppercased(), font: Self.heading, colour: Theme.nine, x: 0, advance: 20))
      switch part.body {
      case .prose(let paragraphs):
        for (at, paragraph) in paragraphs.enumerated() {
          if at > 0 { gap(6) }
          wrap(paragraph, font: Self.text, colour: Theme.ink, x: 0, width: width)
        }
      case .terms(let terms):
        for (at, term) in terms.enumerated() {
          if at > 0 { gap(6) }
          wrap(term.term, font: Self.bold, colour: Theme.ink, x: 0, width: width)
          wrap(term.meaning, font: Self.text, colour: Theme.ink.faded(0.75), x: 0, width: width)
        }
      case .steps(let steps):
        for (at, step) in steps.enumerated() {
          if at > 0 { gap(4) }
          lines.append(
            Line(text: "\(at + 1)", font: Self.bold, colour: Theme.three, x: 0, advance: 0))
          let said = step.lead.isEmpty ? step.rest : step.lead + " " + step.rest
          wrap(said, font: Self.text, colour: Theme.ink, x: 18, width: width - 18)
        }
      case .notes(let notes):
        for (at, note) in notes.enumerated() {
          if at > 0 { gap(4) }
          lines.append(Line(text: "·", font: Self.bold, colour: Theme.three, x: 0, advance: 0))
          wrap(note, font: Self.text, colour: Theme.ink, x: 14, width: width - 14)
        }
      case .keys(let keys):
        canvas.font = Self.bold
        let column = min(width * 0.45, (keys.map { canvas.measure($0.keys) }.max() ?? 0) + 18)
        for key in keys {
          lines.append(
            Line(text: key.keys, font: Self.bold, colour: Theme.ink, x: 0, advance: 0, chip: true))
          wrap(key.does, font: Self.text, colour: Theme.ink.faded(0.8), x: column, width: width - column)
          gap(5)
        }
      }
      if let note = part.note {
        gap(4)
        wrap(note, font: Self.quiet, colour: Theme.dim, x: 0, width: width)
      }
    }
    return lines
  }

  /// The sheet over whatever is under it, which is dimmed: its panel, title and cross, and the
  /// page within the panel, scrolled.
  public func draw(in size: SIMD2<Float>, hovered: SIMD2<Float>?, on canvas: Canvas) {
    canvas.fill = Theme.ground.faded(0.6)
    canvas.fillRect(0, 0, size.x, size.y)
    let frame = Self.frame(in: size)
    Draw.panel(frame, on: canvas)
    canvas.fill = Theme.ground.faded(0.85)
    canvas.fillRect(frame.x + 1, frame.y + 1, frame.width - 2, frame.height - 2)

    canvas.align = .left
    canvas.font = Self.heading
    canvas.fill = Theme.dim
    canvas.fillText(trail.uppercased(), frame.x + 20, frame.y + 26)
    canvas.font = Theme.mono(17, weight: 700)
    canvas.fill = Theme.ink
    canvas.fillText(title, frame.x + 20, frame.y + 50)
    let close = Self.close(in: frame)
    let lit = hovered.map(close.contains) ?? false
    canvas.fill = lit ? Theme.ink : Theme.dim
    let middle = SIMD2(close.x + close.width / 2, close.y + close.height / 2)
    canvas.font = Theme.mono(16, weight: 600)
    canvas.align = .center
    canvas.fillText("×", middle.x, middle.y + 6)
    canvas.align = .left

    let body = Self.body(in: frame)
    if laidOut?.width != body.width {
      let lines = layout(width: body.width, on: canvas)
      laidOut = (body.width, lines)
      contentHeight = lines.reduce(0) { $0 + $1.advance }
      scroll = min(scroll, max(0, contentHeight - body.height))
    }
    canvas.save()
    canvas.clip(body.x, body.y, body.width, body.height)
    var y = body.y - scroll
    for line in laidOut?.lines ?? [] {
      let baseline = y + 12
      if baseline > body.y - Self.lineHeight, baseline < body.maxY + Self.lineHeight, !line.text.isEmpty {
        canvas.font = line.font
        if line.chip {
          canvas.fill = Theme.white(0.08)
          canvas.fillRect(body.x + line.x - 4, baseline - 11, canvas.measure(line.text) + 8, 15)
        }
        canvas.fill = line.colour
        canvas.fillText(line.text, body.x + line.x, baseline)
      }
      y += line.advance
    }
    canvas.restore()
    // How far down it is, when it goes further than it shows.
    if contentHeight > body.height {
      let track = body.height
      let thumb = max(24, track * body.height / contentHeight)
      let at = (track - thumb) * scroll / max(1, contentHeight - body.height)
      canvas.fill = Theme.white(0.18)
      canvas.fillRect(frame.maxX - 6, body.y + at, 3, thumb)
    }
  }
}
