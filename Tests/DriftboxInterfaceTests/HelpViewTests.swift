import DriftboxHelp
import DriftboxInterface
import DriftboxShell
import Testing

/// A guide drawn over the window: its tabs and Close, its topic's words as a screen reader reads
/// them, and the pointer, the wheel and the keys moving about it.
@MainActor
struct HelpViewTests {
  static func view() -> HelpView {
    let view = HelpView(guide: GrooveboxHelp.guide(for: .mac))
    view.size = SIMD2(900, 600)
    return view
  }

  static func tab(_ view: HelpView, _ id: String) throws -> AccessibilityNode {
    try #require(view.accessibility.node("help.topic.\(id)"))
  }

  /// Close, a tab for each topic, the first lit; and every heading, paragraph, term, step and key of
  /// the topic showing, in order, each where it is on the page.
  @Test func aScreenReaderReadsIt() throws {
    let view = Self.view()
    let page = try #require(view.accessibility.node("help"))
    #expect(page.name == "Groovebox guide")
    #expect(page.node("help.close")?.role == .button)
    let tabs = page.children.filter { $0.id.hasPrefix("help.topic.") }
    #expect(tabs.map(\.name) == view.guide.topics.map(\.label))
    #expect(tabs.map(\.isOn) == [true, false, false, false, false])

    let words = page.children.filter { $0.role == .text }
    let first = try #require(view.guide.topics.first)
    #expect(words.first?.name == first.parts.first?.heading)
    #expect(words.contains { $0.name.hasPrefix("Step 1: ") })
    #expect(words.allSatisfy { $0.frame.z > 0 && $0.frame.w > 0 })
    let ys = words.map(\.frame.y)
    #expect(ys == ys.sorted(), "down the page in order")
  }

  /// A tab pressed, by a click or a screen reader, shows its topic from the top; Close closes.
  @Test func topicsAreChosenAndItCloses() throws {
    let view = Self.view()
    let song = try Self.tab(view, "song")
    let at = SIMD2(song.frame.x + song.frame.z / 2, song.frame.y + song.frame.w / 2)
    view.pointer(PointerEvent(phase: .began, location: at))
    #expect(view.guide.topics[view.topic].id == "song")
    #expect(try Self.tab(view, "song").isOn == true)

    #expect(view.perform(.press("help.topic.keys")))
    #expect(view.guide.topics[view.topic].id == "keys")
    #expect(!view.perform(.press("help.topic.nowhere")))
    #expect(view.perform(.press("help.close")))
    #expect(!view.isOpen)
  }

  /// The wheel and the keys scroll it, never past its ends; Left and Right go to the topics beside;
  /// Esc closes it; and every key is its own.
  @Test func theKeysMoveAboutIt() {
    let view = HelpView(guide: GrooveboxHelp.guide(for: .mac))
    view.size = SIMD2(500, 300)
    #expect(view.key(KeyEvent(key: .pageDown)))
    #expect(view.scroll > 0)
    view.scroll(ScrollEvent(location: .zero, delta: SIMD2(0, -10_000)))
    #expect(view.scroll == 0)
    #expect(view.key(KeyEvent(key: .end)))
    let bottom = view.scroll
    #expect(view.key(KeyEvent(key: .down)))
    #expect(view.scroll == bottom, "no further than its end")

    #expect(view.key(KeyEvent(key: .right)))
    #expect(view.topic == 1 && view.scroll == 0)
    #expect(view.key(KeyEvent(key: .left)))
    #expect(view.key(KeyEvent(key: .left)))
    #expect(view.topic == 0)
    #expect(view.key(KeyEvent(key: .character("a"))), "nothing plays under it")
    #expect(view.key(KeyEvent(key: .escape)))
    #expect(!view.isOpen)
  }
}
