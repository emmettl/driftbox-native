import DriftboxHelp
import Testing

/// The guides on Android: the Mac's topics, each with something in it, saying what a finger does —
/// taps, holds, drags — and nothing of keys, a mouse, a menu bar, or what only a desktop or the web
/// has.
struct AndroidHelpTests {
  static let guides = [GrooveboxHelp.guide(for: .android), RackHelp.guide(for: .android)]

  @Test func theTopicsAreTheMacs() {
    #expect(Self.guides[0].topics.map(\.id) == GrooveboxHelp.guide(for: .mac).topics.map(\.id))
    #expect(Self.guides[1].topics.map(\.id) == RackHelp.guide(for: .mac).topics.map(\.id))
    for guide in Self.guides {
      for topic in guide.topics {
        #expect(!topic.parts.isEmpty, "\(guide.title): \(topic.id)")
        #expect(Set(topic.parts.map(\.heading)).count == topic.parts.count, "\(topic.id)'s headings differ")
      }
    }
  }

  /// A phone has no keys to press nor a mouse to click, and no menu bar: nothing here says so.
  @Test func nothingOfKeysOrAMouse() {
    for guide in Self.guides {
      let words = GrooveboxHelpTests.words(guide)
      for elsewhere in [
        "⌘", "⌥", "⇧", "Ctrl", "Alt+", "Alt-", "Shift", "F1", "Tab", "Space", "Esc", "click", "Click",
        "wheel",
        "menu bar", "Settings", "Audio Unit", "VST", "browser", "URL", "Library", "Export",
      ] {
        #expect(!words.contains { $0.contains(elsewhere) }, "\(guide.title): \(elsewhere)")
      }
    }
  }

  /// Each says where it is found again.
  @Test func eachSaysWhereItIs() {
    #expect(GrooveboxHelpTests.words(Self.guides[0]).contains { $0.contains("Groovebox Guide") })
    #expect(GrooveboxHelpTests.words(Self.guides[1]).contains { $0.contains("Rack Guide") })
  }

  /// Each says where undo is, with no Edit menu to find it in, and what a MIDI keyboard plays.
  @Test func eachSaysWhereUndoIsAndWhatAKeyboardPlays() {
    for guide in Self.guides {
      let words = GrooveboxHelpTests.words(guide)
      #expect(words.contains { $0.contains("Undo") && $0.contains("menu") }, "\(guide.title): undo")
      #expect(words.contains { $0.contains("A MIDI keyboard") }, "\(guide.title): a MIDI keyboard")
      #expect(!words.contains { $0.contains("Edit ▸") }, "\(guide.title): no Edit menu")
    }
  }
}
