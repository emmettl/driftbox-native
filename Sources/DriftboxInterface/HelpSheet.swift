import DriftboxCanvas
import DriftboxHelp
import DriftboxShell
import DriftboxText

/// Help drawn over a screen, for the platforms whose screens are drawn: a whole guide, a tab for
/// each of its topics, or a single page of one — a module's guide — under a trail saying whose it
/// is. A panel with its title and Close, and under them the topic's parts, wrapped to its width:
/// headings, paragraphs, terms beside what they mean, numbered steps, keys beside what they do,
/// points, and a quieter note after a part. It scrolls when there is more than it has room for,
/// under a wheel, a finger or the keys, with a bar saying how far down it is. Close, a press off it
/// and Escape put it away; while it is open it has every press and key. A screen reader reads it
/// as it reads the controls.
@MainActor
public final class HelpSheet {
  public let guide: HelpGuide
  /// Whose it is, over its title: "Rack · Filters". Nil for a guide of its own.
  public let trail: String?
  /// The window's size in points.
  public var size: SIMD2<Float> = .zero
  /// The topic showing, by its place in the guide.
  public private(set) var topic = 0
  public private(set) var scroll: Float = 0
  /// False once it has been put away, for whatever shows it to stop.
  public private(set) var isOpen = true
  private var hover: SIMD2<Float>?
  /// A press on it, and whether it has moved far enough to be a scroll rather than a press.
  private var press: (pointer: Int, from: SIMD2<Float>, last: SIMD2<Float>, moved: Bool)?

  /// A guide, from its topic `id`, or its first.
  public init(guide: HelpGuide, topic id: String? = nil) {
    self.guide = guide
    trail = nil
    if let id { show(id) }
  }

  /// One page: a module's guide, under whose it is.
  public init(trail: String, title: String, parts: [HelpPart]) {
    guide = HelpGuide(title: title, topics: [HelpTopic("page", title, parts)])
    self.trail = trail
  }

  public var title: String { guide.title }
  /// The parts of the topic showing.
  public var parts: [HelpPart] { guide.topics.indices.contains(topic) ? guide.topics[topic].parts : [] }

  /// Go to the topic `id`, from its top.
  public func show(_ id: String) {
    guard let at = guide.topics.firstIndex(where: { $0.id == id }) else { return }
    topic = at
    scroll = 0
  }

  public func close() { isOpen = false }

  // MARK: - Where everything is

  /// Something set on the page: words in a font and a colour, at their baseline's start.
  struct Piece {
    var text: String
    var font: FontRequest
    var colour: Colour
    var x: Float
    var y: Float
  }

  /// A part of the page a screen reader reads as one: a heading, a paragraph, a term and its
  /// meaning, where they are before scrolling.
  struct Block {
    var name: String
    var value: String?
    var frame: Rect
  }

  /// The page laid out: the panel, its Close, the tabs where there are topics to choose, and the
  /// topic's pieces and blocks down a column that scrolls, `height` tall.
  struct Page {
    var panel: Rect
    var close: Rect
    var tabs: [(frame: Rect, label: String)]
    var body: Rect
    var pieces: [Piece] = []
    var blocks: [Block] = []
    var height: Float = 0

    var maxScroll: Float { max(0, height - body.height) }
  }

  static let heading = Theme.sans(15, weight: 600)
  static let text = Theme.sans(13)
  static let strong = Theme.sans(13, weight: 600)
  static let quiet = Theme.sans(12)
  static let key = Theme.mono(12, weight: 600)
  static let line: Float = 20

  /// The panel, for a window `size` points across: as wide as reading wants, and the height of the
  /// window, less a margin, which is less on a phone.
  public static func frame(in size: SIMD2<Float>) -> Rect {
    let margin: Float = size.x < 500 ? 10 : 16
    let width = max(0, min(size.x - margin * 2, 760))
    return Rect((size.x - width) / 2, margin, width, max(0, size.y - margin * 2))
  }

  /// How wide `text` is in `font`: the canvas's when there is one, and an estimate otherwise — a
  /// screen reader asking before a frame has been drawn.
  typealias Measure = (String, FontRequest) -> Float
  static func estimate(_ text: String, _ font: FontRequest) -> Float {
    Float(text.count) * font.size * 0.55
  }

  /// The page as it was last laid out, and for what: the canvas measures it once for a size and a
  /// topic, not every frame.
  private var laidOut: (size: SIMD2<Float>, topic: Int, measured: Bool, page: Page)?

  /// The page, laid out afresh only when the window's size or the topic has changed, or it was
  /// last only estimated and a canvas can now measure it.
  func page(measure: Measure? = nil) -> Page {
    if let laid = laidOut, laid.size == size, laid.topic == topic, laid.measured || measure == nil {
      return laid.page
    }
    let page = lay(measure: measure ?? Self.estimate)
    laidOut = (size, topic, measure != nil, page)
    return page
  }

  /// Where the room under the title and the tabs is, for its words.
  public var room: Rect { page().body }
  /// How tall the topic's words are, which is how far down it can scroll.
  public var contentHeight: Float { page().height }

  private func lay(measure: Measure) -> Page {
    let panel = Self.frame(in: size)
    let inset: Float = size.x < 500 ? 14 : 24
    let close = Rect(panel.maxX - inset - 64, panel.y + 14, 64, 28)
    var top = panel.y + (trail == nil ? 58 : 70)
    // The tabs, across under the title, onto another row where they run out of room; none for a
    // single page.
    var tabs: [(Rect, String)] = []
    if guide.topics.count > 1 {
      var x = panel.x + inset
      for topic in guide.topics {
        let width = measure(topic.label, Theme.mono(11)) + 24
        if x + width > panel.maxX - inset, x > panel.x + inset {
          x = panel.x + inset
          top += 34
        }
        tabs.append((Rect(x, top, width, 28), topic.label))
        x += width + 6
      }
      top += 28 + 18
    }
    var page = Page(
      panel: panel, close: close, tabs: tabs,
      body: Rect(panel.x + inset, top, max(0, panel.width - inset * 2), max(0, panel.maxY - 14 - top)))
    lay(parts, on: &page, measure: measure)
    return page
  }

  /// The parts down the page's column.
  private func lay(_ parts: [HelpPart], on page: inout Page, measure: Measure) {
    let left = page.body.x
    let width = page.body.width
    // Terms and keys beside what they mean where the column is wide enough, and over it where not.
    let beside = width >= 480
    let column: Float = beside ? 180 : 0
    var y = page.body.y

    /// Words in runs of fonts and colours, broken onto lines no wider than `width` from `x`; the y
    /// of the line after.
    func set(_ runs: [(String, FontRequest, Colour)], x: Float, width: Float, from top: Float) -> Float {
      var baseline = top + 14
      var at = x
      for (text, font, colour) in runs {
        let space = measure(" ", font)
        // A space more than one between words is kept, as it parts keys: "Page Up  Page Down".
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
          let word = String(word)
          if word.isEmpty {
            if at > x { at += space }
            continue
          }
          let wide = measure(word, font)
          if at > x, at + wide > x + width {
            baseline += Self.line
            at = x
          }
          page.pieces.append(Piece(text: word, font: font, colour: colour, x: at, y: baseline))
          at += wide + space
        }
      }
      return baseline + Self.line - 14
    }
    func block(_ name: String, _ value: String? = nil, from: Float) {
      page.blocks.append(Block(name: name, value: value, frame: Rect(left, from, width, y - from)))
    }

    for part in parts {
      var from = y
      y = set([(part.heading, Self.heading, Theme.ink)], x: left, width: width, from: y) + 4
      block(part.heading, from: from)
      switch part.body {
      case .prose(let paragraphs):
        for paragraph in paragraphs {
          from = y
          y = set([(paragraph, Self.text, Theme.ink.faded(0.86))], x: left, width: width, from: y) + 8
          block(paragraph, from: from)
        }
      case .terms(let terms):
        for term in terms {
          from = y
          let named = set(
            [(term.term, Self.strong, Theme.nine)], x: left, width: beside ? column - 12 : width, from: y)
          let meaning = set(
            [(term.meaning, Self.text, Theme.ink.faded(0.86))], x: left + column, width: width - column,
            from: beside ? y : named)
          y = max(named, meaning) + 8
          block(term.term, term.meaning, from: from)
        }
      case .steps(let steps):
        for (index, step) in steps.enumerated() {
          from = y
          page.pieces.append(
            Piece(text: "\(index + 1)", font: Self.strong, colour: Theme.nine, x: left, y: y + 14))
          let runs = [(step.lead, Self.strong, Theme.ink), (step.rest, Self.text, Theme.ink.faded(0.86))]
          y = set(runs, x: left + 22, width: width - 22, from: y) + 6
          let name = step.lead.isEmpty ? "Step \(index + 1)" : "Step \(index + 1): \(step.lead)"
          block(name, step.rest, from: from)
        }
      case .keys(let keys):
        for key in keys {
          from = y
          let keyed = set(
            [(key.keys, Self.key, Theme.three)], x: left, width: beside ? column - 12 : width, from: y)
          let does = set(
            [(key.does, Self.text, Theme.ink.faded(0.86))], x: left + column, width: width - column,
            from: beside ? y : keyed)
          y = max(keyed, does) + 4
          block(key.keys, key.does, from: from)
        }
      case .notes(let notes):
        for note in notes {
          from = y
          page.pieces.append(Piece(text: "•", font: Self.text, colour: Theme.nine, x: left, y: y + 14))
          y = set([(note, Self.text, Theme.ink.faded(0.86))], x: left + 16, width: width - 16, from: y) + 4
          block(note, from: from)
        }
      }
      if let note = part.note {
        from = y
        y = set([(note, Self.quiet, Theme.dim)], x: left + 12, width: width - 12, from: y) + 6
        block(note, from: from)
      }
      y += 14
    }
    page.height = y - page.body.y
  }

  // MARK: - What it hears

  /// A press, a drag or a finger. A drag scrolls it, wherever it began; a press lifted where it went
  /// down chooses a tab, or puts it away on Close or off the panel. Nothing under it hears any of it.
  public func pointer(_ event: PointerEvent) {
    if event.kind == .mouse { hover = event.phase == .cancelled ? nil : event.location }
    switch event.phase {
    case .began:
      press = (event.id, event.location, event.location, false)
    case .moved:
      guard var held = press, held.pointer == event.id else { return }
      let moved = event.location - held.from
      if !held.moved, (moved * moved).sum() > 64 { held.moved = true }
      if held.moved { scroll(by: held.last.y - event.location.y) }
      held.last = event.location
      press = held
    case .ended:
      guard let held = press, held.pointer == event.id else { return }
      press = nil
      guard !held.moved else { return }
      let page = page()
      if page.close.contains(event.location) || !page.panel.contains(event.location) {
        close()
      } else if let at = page.tabs.firstIndex(where: { $0.frame.contains(event.location) }) {
        topic = at
        scroll = 0
      }
    case .cancelled:
      press = nil
    }
  }

  public func scroll(_ event: ScrollEvent) { scroll(by: event.delta.y) }

  /// Down by `distance` points, or up by a negative one, no further than its ends.
  public func scroll(by distance: Float) {
    scroll = max(0, min(page().maxScroll, scroll + distance))
  }

  /// The keys: Esc puts it away, the arrows and Page Up and Down scroll it, Home and End go to its
  /// ends, and Left and Right to the topics beside. Every key is its own, so nothing under it plays
  /// while it is read.
  public func key(_ event: KeyEvent) -> Bool {
    guard event.isDown else { return true }
    let page = page()
    let screen = max(Self.line, page.body.height - Self.line * 2)
    switch event.key {
    case .escape: close()
    case .up: scroll(by: -Self.line * 2)
    case .down: scroll(by: Self.line * 2)
    case .pageUp: scroll(by: -screen)
    case .pageDown, .space: scroll(by: screen)
    case .home: scroll = 0
    case .end: scroll = page.maxScroll
    case .left:
      topic = max(0, topic - 1)
      scroll = 0
    case .right:
      topic = min(guide.topics.count - 1, topic + 1)
      scroll = 0
    default: break
    }
    return true
  }

  // MARK: - Drawing

  /// The sheet over whatever is on `canvas`, which is dimmed, the canvas's transform taking points
  /// to its pixels.
  public func draw(on canvas: Canvas) {
    let page = page { text, font in
      canvas.font = font
      return canvas.measure(text)
    }
    scroll = min(scroll, page.maxScroll)
    let panel = page.panel
    canvas.fill = Theme.ground.faded(0.72)
    canvas.fillRect(0, 0, size.x, size.y)
    canvas.fill = Theme.ground.faded(0.96)
    canvas.fillRoundedRect(panel.x, panel.y, panel.width, panel.height, radius: 14)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(panel.x, panel.y, panel.width, panel.height, radius: 14)

    let left = page.body.x
    canvas.align = .left
    if let trail {
      canvas.font = Theme.mono(9, weight: 600)
      canvas.fill = Theme.dim
      canvas.fillText(trail.uppercased(), left, panel.y + 28)
    }
    canvas.font = Theme.sans(18, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText(title, left, panel.y + (trail == nil ? 36 : 50))
    Draw.chip(
      page.close, label: "Close", isOn: false, hovered: hover.map(page.close.contains) ?? false, down: false,
      on: canvas)
    for (index, tab) in page.tabs.enumerated() {
      Draw.chip(
        tab.frame, label: tab.label, isOn: index == topic, hovered: hover.map(tab.frame.contains) ?? false,
        down: false, on: canvas)
    }

    let body = page.body
    canvas.save()
    canvas.clip(body.x - 4, body.y, body.width + 8, body.height)
    canvas.translate(0, -scroll)
    // Set from where each word starts: the chips above leave the canvas centring.
    canvas.align = .left
    let shown = (body.y - Self.line + scroll)...(body.maxY + Self.line + scroll)
    for piece in page.pieces where shown.contains(piece.y) {
      canvas.font = piece.font
      canvas.fill = piece.colour
      canvas.fillText(piece.text, piece.x, piece.y)
    }
    canvas.restore()

    // How far down it is, when there is more of it than shows.
    if page.maxScroll > 0 {
      let track = Rect(panel.maxX - 9, body.y, 3, body.height)
      let length = max(24, track.height * body.height / page.height)
      let at = track.y + (track.height - length) * scroll / page.maxScroll
      canvas.fill = Theme.white(0.06)
      canvas.fillRoundedRect(track.x, track.y, track.width, track.height, radius: 1.5)
      canvas.fill = Theme.white(0.3)
      canvas.fillRoundedRect(track.x, at, track.width, length, radius: 1.5)
    }
  }

  // MARK: - Screen readers

  /// The sheet as a screen reader is told it, in the window's place: Close, a tab for each topic,
  /// and the topic's headings, paragraphs, terms, steps, keys and points as words, where they are
  /// on the page now.
  public var accessibility: AccessibilityNode {
    let page = page()
    func frame(_ rect: Rect) -> SIMD4<Float> { SIMD4(rect.x, rect.y, rect.width, rect.height) }
    var children = [
      AccessibilityNode(id: "help.close", role: .button, name: "Close the guide", frame: frame(page.close))
    ]
    for (index, tab) in page.tabs.enumerated() {
      children.append(
        AccessibilityNode(
          id: "help.topic.\(guide.topics[index].id)", role: .toggle, name: tab.label, isOn: index == topic,
          frame: frame(tab.frame)))
    }
    let topicId = guide.topics.indices.contains(topic) ? guide.topics[topic].id : ""
    for (index, block) in page.blocks.enumerated() {
      let at = Rect(block.frame.x, block.frame.y - scroll, block.frame.width, block.frame.height)
      let id = "help.\(topicId).\(index)"
      children.append(
        AccessibilityNode(id: id, role: .text, name: block.name, value: block.value, frame: frame(at)))
    }
    let name = trail.map { "\($0): \(title)" } ?? title
    let sheet = AccessibilityNode(
      id: "help", role: .group, name: name, frame: frame(page.panel), children: children)
    return AccessibilityNode(id: "window", role: .group, name: "", children: [sheet])
  }

  /// What a screen reader asked of the sheet: Close, or a topic's tab.
  @discardableResult
  public func perform(_ asked: AccessibilityAction) -> Bool {
    guard case .press(let id) = asked else { return false }
    if id == "help.close" {
      close()
      return true
    }
    guard let at = guide.topics.firstIndex(where: { "help.topic.\($0.id)" == id }) else { return false }
    topic = at
    scroll = 0
    return true
  }
}
