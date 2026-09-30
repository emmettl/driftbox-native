import Foundation
import Testing

@testable import DriftboxHelp

#if canImport(FoundationXML)
  import FoundationXML
#endif

struct HelpBookTests {
  @Test func everyGuideTopicIsPublishedAndLinked() throws {
    let pages = HelpBook.pages
    #expect(Set(pages.map(\.anchor)).count == pages.count)
    #expect(Set(pages.map(\.filename)).count == pages.count)
    let index = try #require(pages.first)
    #expect(index.anchor == "index")
    for (prefix, guide) in [
      ("groovebox", GrooveboxHelp.guide(for: .mac)), ("rack", RackHelp.guide(for: .mac)),
    ] {
      for topic in guide.topics {
        let page = try #require(pages.first { $0.anchor == prefix + "-" + topic.id })
        #expect(index.html.contains("href=\"\(page.filename)\""))
        for part in topic.parts {
          #expect(page.html.contains(HelpBook.escape(part.heading)))
          for text in part.body.searchText { #expect(page.html.contains(HelpBook.escape(text))) }
          if let note = part.note { #expect(page.html.contains(HelpBook.escape(note))) }
        }
      }
    }
    for page in pages {
      let parser = XMLParser(data: Data(page.html.utf8))
      #expect(parser.parse(), "\(page.filename): \(String(describing: parser.parserError))")
      #expect(page.html.contains("name=\"\(page.anchor)\""))
      #expect(page.html.contains("href=\"index.html\""))
      #expect(!page.html.contains("<script"))
    }
  }

  @Test func contextualLinksResolveToTheSameTopicsAsTheFallback() throws {
    for destination in HelpBook.Destination.allCases {
      #expect(HelpBook.pages.contains { $0.anchor == destination.rawValue })
      let guide = destination.isRack ? RackHelp.guide(for: .mac) : GrooveboxHelp.guide(for: .mac)
      #expect(guide.topic(destination.topic) != nil)
    }
  }

  @Test func htmlEscapesProseAndAttributes() {
    let special = "<input title=\"A&B\">'text'</input>"
    let part = HelpPart(special, .steps([HelpStep(special, special)]), note: special)
    let rendered = HelpBook.render(part)
    #expect(!rendered.contains("<input"))
    #expect(rendered.contains("&lt;input title=&quot;A&amp;B&quot;&gt;&#39;text&#39;&lt;/input&gt;"))
    let html = HelpBook.document(anchor: "test", title: special, description: special, body: rendered)
    #expect(XMLParser(data: Data(html.utf8)).parse())
  }
}
