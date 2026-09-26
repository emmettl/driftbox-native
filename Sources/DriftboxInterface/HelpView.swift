import DriftboxCanvas
import DriftboxHelp
import DriftboxShell
import DriftboxText

/// A guide, drawn over the window as a page of its own: its title and a way to close it, a tab for
/// each topic, and the topic's parts under their headings — paragraphs, terms beside what they
/// mean, numbered steps, keys beside what they do — scrolled by the wheel and the keys. The drawn
/// apps show every guide with it, as the Mac shows one in a window, and a screen reader reads it
/// as it reads the controls.
@MainActor
public final class HelpView {
  public let guide: HelpGuide
  /// The window's size in points.
  public var size: SIMD2<Float> = .zero
  /// The topic showing, by its place in the guide.
  public private(set) var topic = 0
  public private(set) var scroll: Float = 0
  /// False once it has been closed, for the window to stop showing it.
  public private(set) var isOpen = true
  private var hover: SIMD2<Float>?

  public init(guide: HelpGuide, topic id: String? = nil) {
    self.guide = guide
    if let id { show(id) }
  }

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

  /// The page laid out: the panel, the title, the close button and the tabs, and the topic's pieces
  /// and blocks down a column that scrolls, `height` tall.
  struct Page {
    var panel: Rect
    var title: Piece
    var close: Rect
    var tabs: [(frame: Rect, label: String)]
    var content: Rect
    var pieces: [Piece] = []
    var blocks: [Block] = []
    var height: Float = 0

    var maxScroll: Float { max(0, height - content.height) }
  }

  static let heading = Theme.sans(15, weight: 600)
  static let body = Theme.sans(13)
  static let strong = Theme.sans(13, weight: 600)
  static let note = Theme.sans(12)
  static let key = Theme.mono(12, weight: 600)
  static let line: Float = 20

  /// How wide `text` is in `font`: the canvas's when there is one, and an estimate otherwise — a
  /// screen reader asking between frames.
  typealias Measure = (String, FontRequest) -> Float
  static func estimate(_ text: String, _ font: FontRequest) -> Float {
    Float(text.count) * font.size * 0.55
  }

  /// The page as it was last drawn, measured by the canvas, for a screen reader to be told.
  private var drawn: Page?

  func page(measure: Measure) -> Page {
    let width = min(max(0, size.x - 32), 820)
    let panel = Rect((size.x - width) / 2, 16, width, max(0, size.y - 32))
    let inset: Float = 24
    let title = Piece(
      text: guide.title, font: Theme.sans(18, weight: 600), colour: Theme.ink, x: panel.x + inset,
      y: panel.y + 36)
    let close = Rect(panel.maxX - inset - 72, panel.y + 16, 72, 28)
    // The tabs, across under the title, onto another row where they run out of room.
    var tabs: [(Rect, String)] = []
    var x = panel.x + inset
    var y = panel.y + 58
    for topic in guide.topics {
      let tabWidth = measure(topic.label, Theme.mono(11)) + 24
      if x + tabWidth > panel.maxX - inset, x > panel.x + inset {
        x = panel.x + inset
        y += 34
      }
      tabs.append((Rect(x, y, tabWidth, 28), topic.label))
      x += tabWidth + 6
    }
    let top = y + 28 + 18
    var page = Page(
      panel: panel, title: title, close: close, tabs: tabs,
      content: Rect(panel.x + inset, top, max(0, panel.width - inset * 2), max(0, panel.maxY - 16 - top)))
    lay(guide.topics.indices.contains(topic) ? guide.topics[topic] : nil, on: &page, measure: measure)
    return page
  }

  /// A topic's parts down the page's column.
  private func lay(_ topic: HelpTopic?, on page: inout Page, measure: Measure) {
    guard let topic else { return }
    let left = page.content.x
    let width = page.content.width
    // Terms and keys beside what they mean where the column is wide enough, and over it where not.
    let beside = width >= 520
    let column: Float = beside ? 190 : 0
    var y = page.content.y

    /// Words in runs of fonts and colours, broken onto lines no wider than `width` from `x`; the
    /// y of the line after.
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

    for part in topic.parts {
      let headingTop = y
      y = set([(part.heading, Self.heading, Theme.ink)], x: left, width: width, from: y) + 4
      page.blocks.append(Block(name: part.heading, frame: Rect(left, headingTop, width, y - headingTop)))
      switch part.body {
      case .prose(let paragraphs):
        for paragraph in paragraphs {
          let from = y
          y = set([(paragraph, Self.body, Theme.ink.faded(0.86))], x: left, width: width, from: y) + 8
          page.blocks.append(Block(name: paragraph, frame: Rect(left, from, width, y - from)))
        }
      case .terms(let terms):
        for term in terms {
          let from = y
          let named = set(
            [(term.term, Self.strong, Theme.nine)], x: left, width: beside ? column - 12 : width, from: y)
          let meaning = set(
            [(term.meaning, Self.body, Theme.ink.faded(0.86))], x: left + column, width: width - column,
            from: beside ? y : named)
          y = max(named, meaning) + 8
          page.blocks.append(
            Block(name: term.term, value: term.meaning, frame: Rect(left, from, width, y - from)))
        }
      case .steps(let steps):
        for (index, step) in steps.enumerated() {
          let from = y
          page.pieces.append(
            Piece(text: "\(index + 1)", font: Self.strong, colour: Theme.nine, x: left, y: y + 14))
          let runs = [(step.lead, Self.strong, Theme.ink), (step.rest, Self.body, Theme.ink.faded(0.86))]
          y = set(runs, x: left + 22, width: width - 22, from: y) + 6
          page.blocks.append(
            Block(
              name: "Step \(index + 1): \(step.lead)", value: step.rest,
              frame: Rect(left, from, width, y - from)))
        }
      case .notes(let notes):
        for note in notes {
          let from = y
          page.pieces.append(Piece(text: "·", font: Self.strong, colour: Theme.nine, x: left, y: y + 14))
          y = set([(note, Self.body, Theme.ink.faded(0.86))], x: left + 22, width: width - 22, from: y) + 6
          page.blocks.append(Block(name: note, frame: Rect(left, from, width, y - from)))
        }
      case .keys(let keys):
        for key in keys {
          let from = y
          let keyed = set(
            [(key.keys, Self.key, Theme.three)], x: left, width: beside ? column - 12 : width, from: y)
          let does = set(
            [(key.does, Self.body, Theme.ink.faded(0.86))], x: left + column, width: width - column,
            from: beside ? y : keyed)
          y = max(keyed, does) + 4
          page.blocks.append(Block(name: key.keys, value: key.does, frame: Rect(left, from, width, y - from)))
        }
      }
      if let note = part.note {
        let from = y
        y = set([(note, Self.note, Theme.dim)], x: left + 12, width: width - 12, from: y) + 6
        page.blocks.append(Block(name: note, frame: Rect(left, from, width, y - from)))
      }
      y += 14
    }
    page.height = y - page.content.y
  }

  // MARK: - What it hears

  /// A press on a tab shows its topic, and on Close closes it; anything else is the page's, and
  /// nothing under it hears it.
  public func pointer(_ event: PointerEvent) {
    hover = event.phase == .cancelled ? nil : event.location
    guard event.phase == .began else { return }
    let page = drawn ?? page(measure: Self.estimate)
    if page.close.contains(event.location) {
      close()
    } else if let at = page.tabs.firstIndex(where: { $0.frame.contains(event.location) }) {
      topic = at
      scroll = 0
    }
  }

  public func scroll(_ event: ScrollEvent) {
    scrollBy(event.delta.y)
  }

  private func scrollBy(_ distance: Float) {
    let page = drawn ?? page(measure: Self.estimate)
    scroll = max(0, min(page.maxScroll, scroll + distance))
  }

  /// The keys, while it shows: Esc closes it, the arrows and Page Up and Down scroll it, Home and
  /// End go to its ends, and Left and Right to the topics beside. Every key is the page's: nothing
  /// under it plays while it is read.
  public func key(_ event: KeyEvent) -> Bool {
    guard event.isDown else { return true }
    let page = drawn ?? page(measure: Self.estimate)
    let screen = max(Self.line, page.content.height - Self.line * 2)
    switch event.key {
    case .escape: close()
    case .up: scrollBy(-Self.line * 2)
    case .down: scrollBy(Self.line * 2)
    case .pageUp: scrollBy(-screen)
    case .pageDown, .space: scrollBy(screen)
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

  /// The page over whatever is on `canvas`, whose transform takes points to its pixels.
  public func draw(on canvas: Canvas) {
    let page = page { text, font in
      canvas.font = font
      return canvas.measure(text)
    }
    drawn = page
    scroll = min(scroll, page.maxScroll)
    // The window under it dimmed, and the page on it.
    canvas.fill = Theme.ground.faded(0.72)
    canvas.fillRect(0, 0, size.x, size.y)
    canvas.fill = Theme.ground.faded(0.96)
    canvas.fillRoundedRect(page.panel.x, page.panel.y, page.panel.width, page.panel.height, radius: 14)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(page.panel.x, page.panel.y, page.panel.width, page.panel.height, radius: 14)

    canvas.align = .left
    draw(page.title, on: canvas)
    Draw.chip(
      page.close, label: "Close", isOn: false, hovered: hover.map(page.close.contains) ?? false, down: false,
      on: canvas)
    for (index, tab) in page.tabs.enumerated() {
      Draw.chip(
        tab.frame, label: tab.label, isOn: index == topic, hovered: hover.map(tab.frame.contains) ?? false,
        down: false, on: canvas)
    }

    let content = page.content
    canvas.save()
    canvas.clip(content.x - 4, content.y, content.width + 8, content.height)
    canvas.translate(0, -scroll)
    canvas.align = .left
    for piece in page.pieces where piece.y - scroll > content.y - 20 && piece.y - scroll < content.maxY + 20 {
      draw(piece, on: canvas)
    }
    canvas.restore()

    // Where it is in the topic, when there is more of it than shows.
    if page.maxScroll > 0 {
      let track = Rect(page.panel.maxX - 10, content.y, 3, content.height)
      let length = max(24, track.height * content.height / page.height)
      let at = track.y + (track.height - length) * scroll / page.maxScroll
      canvas.fill = Theme.white(0.06)
      canvas.fillRoundedRect(track.x, track.y, track.width, track.height, radius: 1.5)
      canvas.fill = Theme.white(0.3)
      canvas.fillRoundedRect(track.x, at, track.width, length, radius: 1.5)
    }
  }

  private func draw(_ piece: Piece, on canvas: Canvas) {
    canvas.font = piece.font
    canvas.fill = piece.colour
    canvas.fillText(piece.text, piece.x, piece.y)
  }

  // MARK: - Screen readers

  /// The page as a screen reader is told it: Close, a tab for each topic, and the topic's headings,
  /// paragraphs, terms, steps and keys as words, where they are on the page now.
  public var accessibility: AccessibilityNode {
    let page = drawn ?? page(measure: Self.estimate)
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
      children.append(
        AccessibilityNode(
          id: "help.\(topicId).\(index)", role: .text, name: block.name, value: block.value,
          frame: frame(Rect(block.frame.x, block.frame.y - scroll, block.frame.width, block.frame.height))))
    }
    return AccessibilityNode(
      id: "window", role: .group, name: "",
      children: [
        AccessibilityNode(
          id: "help", role: .group, name: guide.title, frame: frame(page.panel), children: children)
      ])
  }

  /// What a screen reader asked of the page: Close, or a topic's tab.
  @discardableResult
  public func perform(_ asked: AccessibilityAction) -> Bool {
    guard case .press(let id) = asked else { return false }
    if id == "help.close" {
      close()
      return true
    }
    guard id.hasPrefix("help.topic."),
      let at = guide.topics.firstIndex(where: { "help.topic.\($0.id)" == id })
    else { return false }
    topic = at
    scroll = 0
    return true
  }
}
