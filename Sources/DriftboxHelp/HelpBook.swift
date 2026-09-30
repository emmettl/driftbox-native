/// The Mac's offline Apple Help pages, generated from the same words as the guide windows.
/// This renderer has no filesystem or platform dependencies, so CI can validate every page.
public enum HelpBook {
  public static let identifier = "app.driftbox.native.help"
  public static let folder = "Driftbox.help"
  public static let title = "Driftbox Help"

  public struct Page: Equatable, Sendable {
    public var anchor: String
    public var title: String
    public var html: String
    public var filename: String { anchor + ".html" }
  }

  /// Stable destinations used by contextual buttons. Tests ensure each resolves to a page.
  public enum Destination: String, CaseIterable, Sendable {
    case song = "groovebox-song"
    case patterns = "groovebox-patterns"
    case sound = "groovebox-sound"
    case troubleshooting = "groovebox-troubleshooting"
    case rack = "rack-start"
    case routing = "rack-modules"

    public var isRack: Bool { rawValue.hasPrefix("rack-") }
    public var topic: String { String(rawValue.dropFirst(isRack ? 5 : 10)) }
  }

  public static var pages: [Page] {
    let guides = [("groovebox", GrooveboxHelp.guide(for: .mac)), ("rack", RackHelp.guide(for: .mac))]
    var pages: [Page] = []
    var contents = "<h1>Driftbox Help</h1><p>Make a song, build a patch, or find a control.</p>"
    for (prefix, guide) in guides {
      contents += "<h2>\(escape(guide.title))</h2><ul>"
      for topic in guide.topics {
        let anchor = prefix + "-" + topic.id
        let title = guide.title + ": " + topic.label
        contents += "<li><a href=\"\(anchor).html\">\(escape(topic.label))</a></li>"
        let body =
          "<p class=\"trail\">\(escape(guide.title))</p><h1>\(escape(topic.label))</h1>"
          + topic.parts.map(render).joined(separator: "\n")
        let description = topic.parts.map(\.heading).joined(separator: "; ")
        pages.append(
          Page(
            anchor: anchor, title: title,
            html: document(anchor: anchor, title: title, description: description, body: body)))
      }
      contents += "</ul>"
    }
    pages.insert(
      Page(
        anchor: "index", title: title,
        html: document(
          anchor: "index", title: title,
          description: "Groovebox and rack guides, walkthroughs, MIDI, files and troubleshooting.",
          body: contents)), at: 0)
    return pages
  }

  static func render(_ part: HelpPart) -> String {
    let body: String
    switch part.body {
    case .prose(let paragraphs): body = paragraphs.map { "<p>\(escape($0))</p>" }.joined()
    case .notes(let notes): body = "<ul>" + notes.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
    case .steps(let steps):
      body =
        "<ol>"
        + steps.map {
          "<li><strong>\(escape($0.lead))</strong> \(escape($0.rest))</li>"
        }.joined() + "</ol>"
    case .terms(let terms):
      body =
        "<dl>"
        + terms.map {
          "<dt>\(escape($0.term))</dt><dd>\(escape($0.meaning))</dd>"
        }.joined() + "</dl>"
    case .keys(let keys):
      body =
        "<dl>"
        + keys.map {
          "<dt><kbd>\(escape($0.keys))</kbd></dt><dd>\(escape($0.does))</dd>"
        }.joined() + "</dl>"
    }
    let note = part.note.map { "<p class=\"note\">\(escape($0))</p>" } ?? ""
    return "<h2>\(escape(part.heading))</h2>" + body + note
  }

  static func document(anchor: String, title: String, description: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="description" content="\(escape(description))" />
    \(anchor == "index" ? "<meta name=\"AppleTitle\" content=\"\(self.title)\" />" : "")
    <title>\(escape(title))</title>
    <link rel="stylesheet" href="help.css" />
    </head>
    <body><a name="\(anchor)" id="\(anchor)"></a>
    <nav aria-label="Help navigation"><a href="index.html">Driftbox Help</a></nav>
    <main>\(body)</main>
    </body></html>
    """
  }

  static func escape(_ text: String) -> String {
    text.reduce(into: "") { result, character in
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
  }

  public static let stylesheet = """
    :root { color-scheme: light dark; }
    body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
      max-width: 740px; margin: 0 auto; padding: 28px; color: #20232a; background: #fafaf8; }
    h1 { font-size: 30px; line-height: 1.2; margin: 16px 0 28px; }
    h2 { font-size: 18px; margin-top: 30px; }
    a { color: #245eb3; text-decoration: underline; }
    a:focus { outline: 2px solid currentColor; outline-offset: 3px; }
    nav, .trail, .note { color: #59616d; font-size: 13px; }
    li { margin: 10px 0; padding-left: 4px; }
    dt { font-weight: 600; margin-top: 14px; }
    dd { margin: 3px 0 0; }
    kbd { font: 13px ui-monospace, monospace; }
    @media (prefers-color-scheme: dark) {
      body { color: #e6e8ed; background: #191c22; }
      a { color: #91bcff; } nav, .trail, .note { color: #b0b7c4; }
    }
    """
}
