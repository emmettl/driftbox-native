#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  /// A module's front: its name and what its jacks add up to, then a control for every param a
  /// hand could set, in cells of one size, three across on a half-width module and seven on a
  /// full one — the reference's generic faceplate, which is what every module has until it has
  /// one of its own.
  struct Faceplate: View {
    let model: RackModel
    let module: PatchModule
    let def: ModuleDef
    let span: Int
    let selected: Bool

    @State private var hovering = false

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        title
        let shown = def.params.filter { !$0.hidden }
        let columns = Array(
          repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: RackLayout.columns(for: span))
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
          ForEach(shown, id: \.id) { param in
            ParamControl(
              def: param, value: model.value(module, param),
              labels: ModuleFace.byType[def.type]?.labels[param.id],
              tint: tint
            ) { value, final in
              if final {
                model.set(module.id, param.id, to: value)
              } else {
                model.turn(module.id, param.id, to: value)
              }
            } end: {
              model.endTurn()
            }
            .frame(width: RackLayout.cellWidth, height: RackLayout.cellHeight)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color(red: 30 / 255, green: 22 / 255, blue: 56 / 255).opacity(0.9),
                Color(red: 16 / 255, green: 11 / 255, blue: 33 / 255).opacity(0.9),
              ],
              startPoint: .top, endPoint: .bottom))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(selected ? Theme.nine : Color.white.opacity(hovering ? 0.16 : 0.09), lineWidth: 1)
          .shadow(color: selected ? Theme.nine.opacity(0.45) : .clear, radius: 8)
      }
      .opacity(module.bypassed ? 0.55 : 1)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: selected)
    }

    private var tint: Color { ModuleFace.accent(ModuleFace.byType[def.type]?.group) }

    private var title: some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(def.name.uppercased())
          .font(.system(size: 11, weight: .semibold)).tracking(0.8)
          .foregroundStyle(Theme.ink)
          .lineLimit(1)
        if def.type == "midi" {
          Text(model.lastNote.map(RackKeyboard.name) ?? "keys")
            .font(Theme.mono(10, .semibold)).foregroundStyle(model.lastNote == nil ? Theme.dim : Theme.nine)
        }
        if module.bypassed {
          Text("bypassed").font(Theme.mono(8.5)).foregroundStyle(Theme.three)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().strokeBorder(Theme.three.opacity(0.5)))
        }
        Spacer(minLength: 4)
        Text(RackLayout.portSummary(def))
          .font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8)).lineLimit(1)
      }
      .frame(height: RackLayout.title - 10, alignment: .center)
      .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1).offset(y: 4) }
    }
  }

  /// One param's control: a knob for a range, buttons for a choice of up to three, and a stepper
  /// for more — a choice is not a knob with positions, and twelve buttons would not fit a cell.
  struct ParamControl: View {
    let def: ParamDef
    let value: Double
    let labels: [String]?
    let tint: Color
    /// A value, and whether it is the last of a gesture.
    let change: (Double, Bool) -> Void
    let end: () -> Void

    var body: some View {
      if def.stepped {
        stepped
      } else {
        let span = def.max - def.min
        RotaryKnob(
          spec: KnobSpec(
            label: def.name, format: { [def] fraction in Self.display(def, def.min + fraction * span) }),
          value: span == 0 ? 0 : max(0, min(1, (value - def.min) / span)), tint: tint,
          rest: span == 0 ? nil : (def.defaultValue - def.min) / span, diameter: 34,
          live: { change(def.min + $0 * span, false) },
          commit: { fraction in
            change(def.min + fraction * span, true)
            end()
          })
      }
    }

    private var count: Int { Int((def.max - def.min).rounded()) + 1 }
    private var current: Int { max(0, min(count - 1, Int(value.rounded()) - Int(def.min))) }
    private func label(_ index: Int) -> String {
      labels.flatMap { index < $0.count ? $0[index] : nil } ?? String(Int(def.min) + index)
    }

    @ViewBuilder private var stepped: some View {
      VStack(spacing: 3) {
        if count <= 3 {
          VStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
              Button(label(index)) { change(def.min + Double(index), true) }
                .buttonStyle(OptionStyle(on: index == current, tint: tint))
            }
          }
          .frame(maxHeight: .infinity)
        } else {
          VStack(spacing: 3) {
            Text(label(current))
              .font(Theme.mono(9.5, .semibold)).foregroundStyle(Theme.ink)
              .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 3) {
              Button("‹") { change(def.min + Double(max(0, current - 1)), true) }
              Button("›") { change(def.min + Double(min(count - 1, current + 1)), true) }
            }
            .buttonStyle(OptionStyle(on: false, tint: tint))
          }
          .frame(maxHeight: .infinity)
        }
        Text(def.name.uppercased())
          .font(Theme.mono(8.5, .medium)).tracking(0.6).foregroundStyle(Theme.dim).lineLimit(1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(def.name)
      .accessibilityValue(label(current))
    }

    /// A value in words, guessed from its range as the reference guesses it: thousands are hertz,
    /// three orders of magnitude inside ten are seconds, a range across ±12 is signed semitones.
    static func display(_ def: ParamDef, _ value: Double) -> String {
      if def.max > 1000 {
        return value >= 1000 ? String(format: "%.2fk", value / 1000) : "\(Int(value.rounded()))"
      }
      if def.max <= 10, def.min >= 0.0001, def.max / max(def.min, 1e-6) > 100 {
        return value < 0.1 ? "\(Int((value * 1000).rounded()))ms" : String(format: "%.2fs", value)
      }
      if def.min <= -12, def.max >= 12 {
        let whole = Int(value.rounded())
        return whole > 0 ? "+\(whole)" : "\(whole)"
      }
      return String(format: "%.2f", value)
    }
  }

  /// A choice's button: small, and lit in the module's colour when it is the one chosen.
  struct OptionStyle: ButtonStyle {
    let on: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(Theme.mono(9, on ? .semibold : .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(on ? Theme.ground : Theme.ink.opacity(0.75))
        .padding(.horizontal, 5)
        .frame(minWidth: 22, minHeight: 13)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(on ? tint : Color.white.opacity(configuration.isPressed ? 0.14 : 0.06))
        )
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
    }
  }
#endif
