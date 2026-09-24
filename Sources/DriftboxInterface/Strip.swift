import DriftboxSeq
import DriftboxSession

extension Layout {
  public static let stripHeight: Float = 60
  public static let patternBarHeight: Float = 28

  /// One entry of the song's chain, drawn to scale: as wide as its bars.
  public struct Section: Equatable {
    public var index: Int
    public var name: String
    public var start: Int
    public var bars: Int
    /// Which colour: patterns in order of first appearance, so the same pattern is always the same
    /// colour within a song.
    public var colour: Int
    public var frame: Rect
    /// The machines playing a pattern of their own in this section.
    public var clips: [ClipSlot] = []
  }

  static let sectionGap: Float = 3

  /// The chain's sections laid along `frame`, and the song's length in bars.
  static func sections(of song: Song, in frame: Rect) -> ([Section], Int) {
    let total = song.chain.reduce(0) { $0 + max(1, $1.repeat) }
    let room = frame.width - sectionGap * Float(max(0, song.chain.count - 1))
    var start = 0
    var x = frame.x
    var colours: [String: Int] = [:]
    let sections = song.chain.enumerated().map { index, entry in
      let bars = max(1, entry.repeat)
      let colour = colours[entry.pattern] ?? colours.count
      colours[entry.pattern] = colour
      let width = max(4, room * Float(bars) / Float(max(1, total)))
      defer {
        start += bars
        x += width + sectionGap
      }
      return Section(
        index: index, name: song.pattern(id: entry.pattern)?.name ?? "?", start: start, bars: bars,
        colour: colour, frame: Rect(x, frame.y, width, frame.height),
        clips: ClipSlot.allCases.filter { entry.clips[$0] != nil })
    }
    return (sections, total)
  }

  /// Where bar `bar` falls along the strip, gaps and all. The end of a bar that ends a section is
  /// that section's right edge, not the next one's left.
  public func x(ofBar bar: Int, end: Bool = false) -> Float {
    for section in sections {
      let into = bar - section.start
      if into >= 0, end ? into <= section.bars : into < section.bars {
        return section.frame.x + section.frame.width * Float(into) / Float(section.bars)
      }
    }
    return sections.last?.frame.maxX ?? sectionsFrame?.x ?? 0
  }

  /// The pattern bar's chips: follow the transport, then each pattern that fits, then one to add a
  /// pattern at the end. A pattern's chip is as wide as its name in the bar's monospace.
  @MainActor
  static func patternChips(
    session: Session, song: Song, shown: DriftboxSeq.Pattern, in bar: Rect,
    renaming: (pattern: String, text: String)? = nil
  ) -> [Chip] {
    let add = Chip(
      frame: Rect(bar.maxX - 26, bar.y, 26, bar.height), label: "+", action: .addPattern, isOn: false)
    var chips = [
      Chip(
        frame: Rect(bar.x + 64, bar.y, 66, bar.height), label: "FOLLOW", action: .follow,
        isOn: session.editing == nil)
    ]
    var x = bar.x + 64 + 66 + 14
    for pattern in song.patterns {
      // The one being renamed as wide as what has been typed, and room for more.
      let typed = renaming?.pattern == pattern.id ? renaming?.text : nil
      let name = typed ?? pattern.name
      let width = 18 + Float(name.count + (typed == nil ? 0 : 1)) * 6.1
      guard x + width <= add.frame.x - 8 else { break }
      chips.append(
        Chip(
          frame: Rect(x, bar.y, width, bar.height), label: name, action: .showPattern(pattern.id),
          isOn: pattern.id == shown.id))
      x += width + 5
    }
    chips.append(add)
    return chips
  }
}
