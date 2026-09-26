#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxEngine
  import DriftboxSeq
  import SwiftUI

  /// What one knob is: what it says, and how it shows its value. The same labels and units as
  /// the web's panels, so a knob is called the same thing on both.
  struct KnobSpec: Sendable {
    let label: String
    var format: @Sendable (Double) -> String = KnobSpec.percent

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))" }
    static func percentOr(_ zero: String) -> @Sendable (Double) -> String {
      { $0 == 0 ? zero : percent($0) }
    }

    /// Left, centre, right: a pan knob's middle is its rest, not fifty of something.
    static func bipolar(_ value: Double) -> String {
      let amount = Int(((value - 0.5) * 200).rounded())
      return amount == 0 ? "C" : amount < 0 ? "L\(-amount)" : "R\(amount)"
    }

    /// A drum voice's six, the same on every voice: where decay is is learnt once.
    static let voice: [KnobSpec] = [
      KnobSpec(label: "Level"), KnobSpec(label: "Tune"), KnobSpec(label: "Decay"),
      KnobSpec(label: "Tone"), KnobSpec(label: "Colour"), KnobSpec(label: "Pan", format: bipolar),
    ]

    static let sends: [KnobSpec] = [KnobSpec(label: "Delay"), KnobSpec(label: "Reverb")]

    /// A 303's, the ones on the front of the machine.
    static let bass: [KnobSpec] = [
      KnobSpec(label: "Tune"), KnobSpec(label: "Wave", format: { $0 < 0.5 ? "saw" : "sqr" }),
      KnobSpec(label: "Cutoff"), KnobSpec(label: "Reso"), KnobSpec(label: "Env Mod"),
      KnobSpec(label: "Decay"), KnobSpec(label: "Accent"), KnobSpec(label: "Level"),
    ]

    /// The master path, in `FxParams.names` order, each in its own units: a filter in hertz, a
    /// delay in sixteenths because that is what it snaps to, a reverb in seconds.
    static let fx: [KnobSpec] = [
      KnobSpec(label: "Drive", format: percentOr("clean")),
      KnobSpec(label: "PCF", format: percentOr("off")),
      KnobSpec(label: "Cutoff", format: { "\(Int(MasterInserts.filterFrequency($0).rounded()))Hz" }),
      KnobSpec(label: "Reso"),
      KnobSpec(label: "Env"),
      KnobSpec(
        label: "Decay", format: { "\(Int((MasterInserts.filterDecaySeconds($0) * 1000).rounded()))ms" }),
      KnobSpec(label: "Comp", format: percentOr("off")),
      KnobSpec(label: "Time", format: { "\(delayDivision($0))/16" }),
      KnobSpec(label: "F.back"),
      KnobSpec(label: "Tone"),
      KnobSpec(label: "Size", format: { String(format: "%.1fs", 0.3 + $0 * 3.5) }),
      KnobSpec(label: "Damp"),
    ]

    /// The master path's knobs by what they belong to, as indices into `fx`.
    static let fxGroups: [(name: String, knobs: [Int])] = [
      ("Insert", [0, 6]), ("Filter", [1, 2, 3, 4, 5]), ("Delay", [7, 8, 9]), ("Reverb", [10, 11]),
    ]
  }

  /// A knob, turned by dragging up and down — every hardware editor settled on that, because a
  /// knob that follows the pointer round a circle is fiddly. Option slows it for fine work, a
  /// double-click puts it back where it started life, and the arrow keys nudge it. The song
  /// is only changed when the drag ends, so one turn is one undo; `live`, where it is given, hears
  /// every value on the way, for something that should sound as it turns.
  struct RotaryKnob: View {
    let spec: KnobSpec
    let value: Double
    var tint: Color = Theme.nine
    var rest: Double?
    var diameter: CGFloat = 40
    /// Each move while it is dragged, where the song hears the knob as it turns.
    var live: ((Double) -> Void)?
    /// A drag let go of, however it ended.
    var ended: (() -> Void)?
    let commit: (Double) -> Void

    @State private var dragging: Double?
    @State private var from = 0.0
    @State private var hovering = false
    @FocusState private var focused: Bool

    /// Degrees of travel, leaving a gap at the bottom like a real knob.
    static let sweep = 270.0
    /// Points of drag for the whole travel; four times as many with Option held.
    static let travel = 170.0

    private var shown: Double { dragging ?? value }

    var body: some View {
      VStack(spacing: 3) {
        dial
          .frame(width: diameter, height: diameter)
          .contentShape(Circle())
          .gesture(drag)
          .onTapGesture(count: 2) { if let rest { commit(rest) } }
          .onHover { hovering = $0 }
          .focusable()
          .focused($focused)
          .focusEffectDisabled()
          .onKeyPress(.upArrow) { nudge(+1) }
          .onKeyPress(.rightArrow) { nudge(+1) }
          .onKeyPress(.downArrow) { nudge(-1) }
          .onKeyPress(.leftArrow) { nudge(-1) }
        Text(spec.label.uppercased())
          .font(Theme.mono(8.5, .medium)).tracking(0.6).foregroundStyle(Theme.dim).lineLimit(1)
        Text(spec.format(shown))
          .font(Theme.mono(9.5).monospacedDigit())
          .foregroundStyle(dragging == nil ? Theme.ink.opacity(0.55) : Theme.ink)
          .lineLimit(1)
      }
      .frame(minWidth: diameter + 12)
      .accessibilityElement()
      .accessibilityLabel(spec.label)
      .accessibilityValue(spec.format(value))
      .accessibilityAdjustableAction { direction in
        _ = nudge(direction == .increment ? 1 : -1)
      }
    }

    private var dial: some View {
      let fraction = Self.sweep / 360
      let active = dragging != nil || focused
      return ZStack {
        // The body: a dark cap, lit from above, so it reads as a thing that turns.
        Circle()
          .fill(
            LinearGradient(
              colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)], startPoint: .top,
              endPoint: .bottom)
          )
          .padding(diameter * 0.2)
          .overlay(Circle().strokeBorder(Color.white.opacity(0.1)).padding(diameter * 0.2))
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(135))
          .padding(2)
        Circle()
          .trim(from: 0, to: fraction * max(0.0001, shown))
          .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(135))
          .padding(2)
          .shadow(color: tint.opacity(active ? 0.8 : hovering ? 0.45 : 0.25), radius: active ? 6 : 3)
        Capsule()
          .fill(Theme.ink)
          .frame(width: 2, height: diameter * 0.22)
          .offset(y: -diameter * 0.19)
          .rotationEffect(.degrees(-Self.sweep / 2 + shown * Self.sweep))
      }
      // An undo, or a song opening, swings the knob round rather than jumping it; a drag is
      // the hand itself and follows exactly.
      .animation(dragging == nil ? .spring(response: 0.35, dampingFraction: 0.72) : nil, value: shown)
      .scaleEffect(dragging == nil ? 1 : 1.06)
      .animation(.spring(response: 0.2, dampingFraction: 0.6), value: dragging == nil)
    }

    private var drag: some Gesture {
      DragGesture(minimumDistance: 0)
        .onChanged { gesture in
          if dragging == nil {
            from = value
            focused = true
          }
          let fine = NSEvent.modifierFlags.contains(.option)
          let moved = -gesture.translation.height / (fine ? Self.travel * 4 : Self.travel)
          let next = max(0, min(1, from + moved))
          if next != dragging { live?(next) }
          dragging = next
        }
        .onEnded { _ in
          if let dragging, dragging != value { commit(dragging) }
          dragging = nil
          ended?()
        }
    }

    private func nudge(_ direction: Double) -> KeyPress.Result {
      let step = NSEvent.modifierFlags.contains(.option) ? 0.01 : 0.05
      commit(max(0, min(1, value + direction * step)))
      return .handled
    }
  }
#endif
