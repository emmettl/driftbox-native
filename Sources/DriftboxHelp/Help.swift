/// Help, in words only: a guide of topics, each a tab of parts under headings. Every platform lays
/// it out as its own — a Mac window, the drawn apps' pages — and says what that platform's own
/// controls do, so what it says is chosen by `HelpPlatform`.
public struct HelpGuide: Equatable, Sendable {
  /// "Groovebox guide".
  public var title: String
  public var topics: [HelpTopic]

  public init(title: String, topics: [HelpTopic]) {
    self.title = title
    self.topics = topics
  }

  public func topic(_ id: String) -> HelpTopic? { topics.first { $0.id == id } }

  /// Search headings and the complete text, retaining each matching part's context. Whitespace
  /// alone restores the guide; multiple words must all occur in the same part or its topic label.
  /// Standard-library text operations keep this available to the Android build too.
  public func matching(_ query: String) -> [HelpTopic] {
    let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard !words.isEmpty else { return topics }
    return topics.compactMap { topic in
      let parts = topic.parts.filter { part in
        let text = ([topic.label, part.heading, part.note ?? ""] + part.body.searchText)
          .joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
      }
      return parts.isEmpty ? nil : HelpTopic(topic.id, topic.label, parts)
    }
  }
}

public struct HelpTopic: Equatable, Sendable, Identifiable {
  public var id: String
  /// Its tab: "Start here".
  public var label: String
  public var parts: [HelpPart]

  public init(_ id: String, _ label: String, _ parts: [HelpPart]) {
    self.id = id
    self.label = label
    self.parts = parts
  }
}

/// A heading, what is under it, and a note after it in a quieter voice.
public struct HelpPart: Equatable, Sendable {
  public var heading: String
  public var body: HelpBody
  public var note: String?

  public init(_ heading: String, _ body: HelpBody, note: String? = nil) {
    self.heading = heading
    self.body = body
    self.note = note
  }
}

public enum HelpBody: Equatable, Sendable {
  /// Paragraphs.
  case prose([String])
  /// Terms and what each means.
  case terms([HelpTerm])
  /// Steps in order, each led by what to do.
  case steps([HelpStep])
  /// Keys and what each does.
  case keys([HelpKey])
  /// Points, in no order.
  case notes([String])

  var searchText: [String] {
    switch self {
    case .prose(let paragraphs), .notes(let paragraphs): paragraphs
    case .terms(let terms): terms.flatMap { [$0.term, $0.meaning] }
    case .steps(let steps): steps.flatMap { [$0.lead, $0.rest] }
    case .keys(let keys): keys.flatMap { [$0.keys, $0.does] }
    }
  }
}

public struct HelpTerm: Equatable, Sendable {
  public var term: String
  public var meaning: String

  public init(_ term: String, _ meaning: String) {
    self.term = term
    self.meaning = meaning
  }
}

public struct HelpStep: Equatable, Sendable {
  /// What to do, said strongly: "Press play." Empty for a step said all in one voice.
  public var lead: String
  public var rest: String

  public init(_ lead: String, _ rest: String) {
    self.lead = lead
    self.rest = rest
  }
}

public struct HelpKey: Equatable, Sendable {
  public var keys: String
  public var does: String

  public init(_ keys: String, _ does: String) {
    self.keys = keys
    self.does = does
  }
}

/// Whose controls the help describes. The words follow the reference's guide where the controls
/// are the same, and say what each platform's own are where they are not.
public enum HelpPlatform: Sendable {
  case mac
  /// The drawn app on Windows: its menus, its keys with Ctrl, and what its drawn controls do.
  case windows
  /// The touchscreen app on Android: its chips, long presses and fingers, and no keys.
  case android
}
