#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRackSession
  import SwiftUI

  /// A guided tour's panel, in the rack's corner rather than over it, since the rack is what it asks
  /// to be touched: where to look, what to do and why, the steps ticked as they are done, and a way
  /// past a step or out. It decides nothing about the patch — `RackSession` does, from the rack as it
  /// is — and at the end it says what was skipped, and offers the patch the rack had before.
  struct TourCoach: View {
    let model: RackSession
    @State private var folded = false
    /// Ended before its steps were: the same choice as at the end, of this patch or the one before.
    @State private var ending = false

    var body: some View {
      if let run = model.tourRun {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text("GUIDED TOUR").font(Theme.mono(8.5, .semibold)).tracking(0.8).foregroundStyle(Theme.dim)
              Text(run.tour.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
            }
            Spacer()
            Text("\(run.marks.filter { $0 == .done }.count) of \(run.tour.steps.count)")
              .font(Theme.mono(10)).foregroundStyle(Theme.dim)
            Button(folded ? "Show" : "Hide") { withAnimation(.spring(response: 0.3)) { folded.toggle() } }
              .buttonStyle(.chip(on: false, tint: Theme.nine, size: 10))
          }
          if !folded {
            if run.at < run.tour.steps.count, !ending {
              current(run.tour.steps[run.at])
            } else {
              end(run)
            }
            checklist(run)
          }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ground.opacity(0.94)))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.nine.opacity(0.35))
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .onChange(of: run.tour.id) { ending = false }
      }
    }

    private func current(_ step: RackTourStep) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(step.place.uppercased()).font(Theme.mono(8.5, .semibold)).tracking(0.8)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(Theme.nine.opacity(0.16))).foregroundStyle(Theme.nine)
        Text(step.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(step.body).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.72))
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Skip") { model.skipTourStep() }
            .buttonStyle(.chip(on: false, tint: Theme.dim, size: 10))
            .help("Pass over this step for now; do it later and it still ticks")
          Button("End Tour") {
            // With a patch of the rack's own to go back to, ending is a choice; without, it just ends.
            if model.tourRun?.before == nil { model.closeTour() } else { ending = true }
          }
          .buttonStyle(.chip(on: false, tint: Theme.dim, size: 10))
        }
      }
    }

    private func end(_ run: RackSession.TourRun) -> some View {
      let skipped = run.marks.filter { $0 == .skipped }.count
      let left = run.marks.filter { $0 == .todo }.count
      return VStack(alignment: .leading, spacing: 8) {
        Text(
          left > 0
            ? "Ended with \(left) step\(left == 1 ? "" : "s") to go."
            : skipped == 0 ? "Every step done." : "Done, but for \(skipped) skipped."
        )
        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
        Text(
          skipped == 0
            ? "Keep going with the patch you have built, or go back to the one you had."
            : "A skipped step still ticks if you do it while this is open."
        )
        .font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          if let before = run.before {
            Button("Back to \(before.name)") { model.closeTour(goingBack: true) }
              .buttonStyle(.chip(on: false, tint: Theme.three, size: 10))
          }
          Button("Keep This Patch") { model.closeTour() }
            .buttonStyle(.chip(on: true, tint: Theme.nine, size: 10))
        }
      }
    }

    private func checklist(_ run: RackSession.TourRun) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(run.tour.steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Group {
              switch run.marks[index] {
              case .done: Image(systemName: "checkmark").foregroundStyle(Theme.nine)
              case .skipped: Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.dim)
              case .todo:
                Image(systemName: index == run.at ? "circle.fill" : "circle")
                  .foregroundStyle(index == run.at ? Theme.three : Theme.dim)
              }
            }
            .font(.system(size: 9, weight: .bold))
            .frame(width: 12)
            Text(step.title).font(.system(size: 11))
              .foregroundStyle(run.marks[index] == .done ? Theme.dim : Theme.ink.opacity(0.85))
              .strikethrough(run.marks[index] == .done, color: Theme.dim)
              .lineLimit(1)
          }
        }
      }
      .padding(.top, 2)
      .animation(.spring(response: 0.3), value: run.marks)
    }
  }

  /// The rack's first offer of a tour, once: to somebody who has not taken one, the first one, in a
  /// few minutes, or not now.
  struct TourOffer: View {
    let model: RackSession

    var body: some View {
      if model.offersFirstTour, let first = RackTour.all(for: .mac).first {
        VStack(alignment: .leading, spacing: 8) {
          Text("New to the rack?").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
          Text(
            "\(first.name) takes about \(first.minutes) minutes: add an instrument, play it, and turn the rack round."
          )
          .font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.72))
          .fixedSize(horizontal: false, vertical: true)
          HStack {
            Spacer()
            Button("Not Now") { model.tourOffered = true }
              .buttonStyle(.chip(on: false, tint: Theme.dim, size: 10))
            Button("Take the Tour") { model.startTour(first) }
              .buttonStyle(.chip(on: true, tint: Theme.nine, size: 10))
          }
          Text("Every tour is in Help ▸ Rack Tours.").font(Theme.mono(9)).foregroundStyle(Theme.dim)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ground.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.edge))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
      }
    }
  }

  extension View {
    /// A ring that breathes round what the tour's step points at, while it does.
    func tourSpot(_ lit: Bool) -> some View {
      overlay {
        if lit {
          TimelineView(.animation) { time in
            let breath = 0.55 + 0.45 * sin(time.date.timeIntervalSinceReferenceDate * 3.2)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(Theme.nine.opacity(breath), lineWidth: 2)
              .shadow(color: Theme.nine.opacity(0.6 * breath), radius: 8)
              .padding(-4)
          }
          .allowsHitTesting(false)
        }
      }
    }
  }
#endif
