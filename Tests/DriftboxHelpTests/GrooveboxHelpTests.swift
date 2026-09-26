import DriftboxHelp
import Testing

/// The groovebox's guide: the reference's topics, in its order, each with something in it, and
/// nothing said about what only the web app has.
struct GrooveboxHelpTests {
  static let mac = GrooveboxHelp.guide(for: .mac)

  @Test func theTopicsAreTheReferences() {
    #expect(Self.mac.title == "Groovebox guide")
    #expect(Self.mac.topics.map(\.id) == ["start", "patterns", "song", "sound", "keys"])
    for topic in Self.mac.topics {
      #expect(!topic.parts.isEmpty, "\(topic.id)")
      #expect(Set(topic.parts.map(\.heading)).count == topic.parts.count, "\(topic.id)'s headings differ")
    }
    #expect(Self.mac.topic("song")?.label == "Song & automation")
    #expect(Self.mac.topic("nothing") == nil)
  }

  /// A browser's library, a link to share and the web's reset are the web's alone.
  @Test func nothingOnlyTheWebHas() {
    let words = Self.mac.topics.flatMap { topic in
      topic.parts.flatMap { part -> [String] in
        var said = [part.heading] + (part.note.map { [$0] } ?? [])
        switch part.body {
        case .prose(let paragraphs): said += paragraphs
        case .terms(let terms): said += terms.flatMap { [$0.term, $0.meaning] }
        case .steps(let steps): said += steps.flatMap { [$0.lead, $0.rest] }
        case .keys(let keys): said += keys.flatMap { [$0.keys, $0.does] }
        case .notes(let notes): said += notes
        }
        return said
      }
    }
    for web in ["browser", "URL", "Share", "Library", "Backspace", "Enter "] {
      #expect(!words.contains { $0.contains(web) }, "\(web)")
    }
  }
}
