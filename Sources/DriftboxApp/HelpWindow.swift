#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxHelp
  import SwiftUI

  /// A guide in a window of its own, beside what it describes rather than over it: its topics down
  /// the side, as the reference's guide has them across the top, and the one chosen beside them.
  public struct HelpWindow: View {
    let guide: HelpGuide
    @State private var topic: String?

    /// The groovebox's guide, as it is on the Mac.
    public init() {
      self.init(guide: GrooveboxHelp.guide(for: .mac))
    }

    init(guide: HelpGuide) {
      self.guide = guide
    }

    public var body: some View {
      NavigationSplitView {
        List(guide.topics, selection: $topic) { topic in
          Text(topic.label).tag(topic.id)
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
      } detail: {
        ScrollView {
          if let shown = guide.topic(topic ?? guide.topics.first?.id ?? "") {
            HelpTopicView(topic: shown, title: guide.title)
          }
        }
        .background(Theme.ground)
      }
      .onAppear { if topic == nil { topic = guide.topics.first?.id } }
    }
  }

  /// One topic's parts, one under another.
  struct HelpTopicView: View {
    let topic: HelpTopic
    let title: String

    var body: some View {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title.uppercased()).font(Theme.mono(8.5, .medium)).tracking(0.8).foregroundStyle(Theme.dim)
          Text(topic.label).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
        }
        ForEach(Array(topic.parts.enumerated()), id: \.offset) { _, part in
          VStack(alignment: .leading, spacing: 8) {
            Text(part.heading.uppercased()).font(Theme.mono(9, .semibold)).tracking(0.9)
              .foregroundStyle(Theme.nine)
            HelpBodyView(content: part.body)
            if let note = part.note {
              Text(note).font(.system(size: 12)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// What is under a heading, as its kind wants: paragraphs, terms, steps or keys.
  struct HelpBodyView: View {
    let content: HelpBody

    var body: some View {
      switch content {
      case .prose(let paragraphs):
        VStack(alignment: .leading, spacing: 8) {
          ForEach(paragraphs, id: \.self) { paragraph in
            Text(paragraph).font(.system(size: 13)).foregroundStyle(Theme.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      case .terms(let terms):
        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
            VStack(alignment: .leading, spacing: 2) {
              Text(term.term).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
              Text(term.meaning).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      case .steps(let steps):
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 9) {
              Text("\(index + 1)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.three)
              (Text(step.lead).bold() + Text(step.lead.isEmpty ? step.rest : " " + step.rest))
                .font(.system(size: 13)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      case .notes(let notes):
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("·").foregroundStyle(Theme.three)
              Text(note).font(.system(size: 13)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      case .keys(let keys):
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
          ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
            GridRow {
              Text(key.keys).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                // The same width in every part, so what the keys do lines up down the page.
                .frame(minWidth: 130, alignment: .leading)
              Text(key.does).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.8))
            }
          }
        }
      }
    }
  }
#endif
