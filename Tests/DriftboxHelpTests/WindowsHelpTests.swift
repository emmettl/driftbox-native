import DriftboxHelp
import Testing

/// The guides on Windows: the Mac's topics, each with something in it, saying what the drawn app's
/// controls do in Windows' words — Ctrl, not ⌘ — and nothing only the Mac or the web has.
struct WindowsHelpTests {
  static let guides = [GrooveboxHelp.guide(for: .windows), RackHelp.guide(for: .windows)]

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

  /// The Mac's keys and places are not Windows': no ⌘, ⌥ or ⇧, no Option, no sidebar or Settings
  /// window, no Finder; and nothing only the web has.
  @Test func nothingOnlyTheMacOrTheWebHas() {
    for guide in Self.guides {
      let words = GrooveboxHelpTests.words(guide)
      for elsewhere in [
        "⌘", "⌥", "⇧", "↩", "Option", "sidebar", "Settings", "Finder", "Audio Unit", "browser", "URL",
        "Library",
      ] {
        #expect(!words.contains { $0.contains(elsewhere) }, "\(guide.title): \(elsewhere)")
      }
    }
  }

  /// Each says how to open it again.
  @Test func eachSaysF1() {
    for guide in Self.guides {
      #expect(GrooveboxHelpTests.words(guide).contains("F1"), "\(guide.title)")
    }
  }
}
