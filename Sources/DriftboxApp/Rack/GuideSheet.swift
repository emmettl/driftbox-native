#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRackSession
  import SwiftUI

  /// A module's guide, over the rack: the reference's `ModuleGuide`, laid out as a Mac sheet. What
  /// it says is `RackGuide`'s, which every platform shows.
  struct GuideSheet: View {
    let guide: RackGuide
    let close: () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text(guide.trail.uppercased()).font(Theme.mono(8.5, .medium)).tracking(0.8)
              .foregroundStyle(Theme.dim)
            Text(guide.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
          }
          Spacer()
          Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(20)
        Divider().overlay(Theme.edge)
        ScrollView { GuidePage(guide: guide) }
      }
      .frame(width: 520, height: 560)
      .background(Theme.ground)
    }
  }

  /// A guide's parts, one under another: a heading each, and what is under it as its kind of
  /// section wants.
  struct GuidePage: View {
    let guide: RackGuide

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        ForEach(Array(guide.parts.enumerated()), id: \.offset) { _, part in
          VStack(alignment: .leading, spacing: 7) {
            Text(part.heading.uppercased()).font(Theme.mono(9, .semibold)).tracking(0.9)
              .foregroundStyle(Theme.nine)
            body(of: part.body)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func body(of section: RackGuide.Section) -> some View {
      switch section {
      case .prose(let text):
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize(
          horizontal: false, vertical: true)
      case .flow(let ins, let outs, let noIns, let noOuts):
        HStack(alignment: .top, spacing: 14) {
          ports("In", ins, none: noIns)
          Text("→").foregroundStyle(Theme.dim)
          ports("Out", outs, none: noOuts)
        }
      case .definitions(let terms):
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
            VStack(alignment: .leading, spacing: 2) {
              Text(term.term).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
              Text(term.meaning).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      case .steps(let steps):
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("\(index + 1)").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.three)
              Text(step).font(.system(size: 13)).foregroundStyle(Theme.ink)
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
      }
    }

    private func ports(_ label: String, _ names: [String], none: String) -> some View {
      VStack(alignment: .leading, spacing: 3) {
        Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
        if names.isEmpty {
          Text(none).font(.system(size: 12)).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(names, id: \.self) {
            Text($0).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.8))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
#endif
