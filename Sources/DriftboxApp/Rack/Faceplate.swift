#if canImport(SwiftUI) && canImport(AVFoundation)
  import DriftboxRack
  import SwiftUI

  /// A module's front: the panel every module has — its ground, its edge, lit when selected and
  /// dimmed when bypassed — and in it either the module's own hand-built face or the reference's
  /// generic one: its name and what its jacks add up to, then a control for every param a hand
  /// could set, in cells of one size, three across on a half-width module and seven on a full one.
  struct Faceplate: View {
    let model: RackModel
    let module: PatchModule
    let def: ModuleDef
    let span: Int
    let selected: Bool

    @State private var hovering = false

    var body: some View {
      let face = FaceContext(model: model, module: module, def: def)
      VStack(alignment: .leading, spacing: 6) {
        switch def.type {
        case "vco": VcoFace(face: face)
        case "ladder": LadderFace(face: face)
        case "out": OutFace(face: face)
        case "midi": MidiFace(face: face)
        case "tuner": TunerFace(face: face)
        case "meter": MeterFace(face: face)
        case "looper": LooperFace(face: face)
        case "tracker": TrackerFace(face: face)
        case "arranger": ArrangerFace(face: face)
        case "scale-player": ScalePlayerFace(face: face)
        case "note-echo": NoteEchoFace(face: face)
        case "chord-player": ChordPlayerFace(face: face)
        case "arp": ArpFace(face: face)
        case "combi": CombinatorFace(face: face)
        case "sampler": SamplerFace(face: face)
        case "multisampler": MultisamplerFace(face: face)
        case "audio-track": AudioTrackFace(face: face)
        case "groovebox": GrooveboxFace(face: face)
        case "plugin", "plugin-instrument": PluginFace(face: face)
        default: GenericFace(face: face, span: span)
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // A face never spills out of its module, whatever it is given to show.
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
      .overlay(alignment: .topTrailing) {
        if module.bypassed {
          Text("bypassed").font(Theme.mono(8.5)).foregroundStyle(Theme.three)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Theme.ground).strokeBorder(Theme.three.opacity(0.5)))
            .offset(x: -10, y: -7)
        }
      }
      .opacity(module.bypassed ? 0.55 : 1)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: selected)
    }
  }

  /// What a face is given: the module, its definition, and a way to read and turn its knobs —
  /// the reference's `FaceplateProps`, and nothing else, so a face cannot reach past its module.
  @MainActor
  struct FaceContext {
    let model: RackModel
    let module: PatchModule
    let def: ModuleDef

    var tint: Color { ModuleFace.accent(ModuleFace.byType[def.type]?.group) }
    var reading: MeterReading? { model.readings[module.id] }

    func param(_ id: String) -> ParamDef? { def.params.first { $0.id == id } }

    func value(_ id: String) -> Double {
      guard let param = param(id) else { return 0 }
      return model.value(module, param)
    }

    func set(_ id: String, _ value: Double) { model.set(module.id, id, to: value) }

    /// The control for one param, as the generic face draws it, in a cell of the usual size.
    @ViewBuilder
    /// `named` puts a shorter name under it, where the face already says whose control it is.
    func control(
      _ id: String, tint: Color? = nil, diameter: CGFloat = 34, options: [String]? = nil, named: String? = nil
    ) -> some View {
      if let param = param(id) {
        let shown =
          named.map { name in
            var renamed = param
            renamed.name = name
            return renamed
          } ?? param
        ParamControl(
          def: shown, value: value(id), labels: options ?? ModuleFace.byType[def.type]?.labels[id],
          tint: tint ?? self.tint, diameter: diameter, routed: model.isRouted(module.id, id)
        ) { value, final in
          if final { model.set(module.id, id, to: value) } else { model.turn(module.id, id, to: value) }
        } end: {
          model.endTurn()
        }
        .frame(width: RackLayout.cellWidth, height: max(RackLayout.cellHeight, diameter + 28))
      }
    }
  }

  /// A face's title: the name, a model mark in the module's colour where it has one, and a word
  /// at the right about what it is doing.
  struct PanelTitle<Trailing: View>: View {
    let name: String
    var mark: String?
    var markTint: Color = Theme.three
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
      HStack(alignment: .center, spacing: 8) {
        Text(name.uppercased())
          .font(.system(size: 11, weight: .semibold)).tracking(0.8)
          .foregroundStyle(Theme.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .layoutPriority(1)
        if let mark {
          Text(mark).font(Theme.mono(8)).tracking(1.1).foregroundStyle(markTint)
        }
        Spacer(minLength: 4)
        trailing()
      }
      .frame(height: RackLayout.title - 10, alignment: .center)
      .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1).offset(y: 4) }
    }
  }

  extension PanelTitle where Trailing == Text {
    init(name: String, mark: String? = nil, markTint: Color = Theme.three, words: String) {
      self.init(name: name, mark: mark, markTint: markTint) {
        Text(words).font(Theme.mono(9)).foregroundStyle(Theme.dim.opacity(0.8))
      }
    }
  }

  /// The face every module has until it has its own.
  struct GenericFace: View {
    let face: FaceContext
    let span: Int

    var body: some View {
      PanelTitle(name: face.def.name, words: RackLayout.portSummary(face.def))
      let columns = Array(
        repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: RackLayout.columns(for: span))
      LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
        ForEach(face.def.params.filter { !$0.hidden }, id: \.id) { param in
          face.control(param.id)
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// One param's control: a knob for a range, buttons for a choice of up to three, and a stepper
  /// for more — a choice is not a knob with positions, and twelve buttons would not fit a cell.
  struct ParamControl: View {
    let def: ParamDef
    let value: Double
    let labels: [String]?
    let tint: Color
    var diameter: CGFloat = 34
    /// A Combinator drives it. Marked rather than disabled, as the reference marks it: it still
    /// turns, and the routing takes it back, and a dead knob would say less about why.
    var routed = false
    /// A value, and whether it is the last of a gesture.
    let change: (Double, Bool) -> Void
    let end: () -> Void

    var body: some View {
      control
        .overlay(alignment: .topTrailing) {
          if routed {
            Circle().fill(Theme.three).frame(width: 5, height: 5)
              .shadow(color: Theme.three, radius: 3)
              .padding(.trailing, 6)
              .help("\(def.name) is driven by a Combinator")
              .accessibilityHidden(true)
          }
        }
    }

    @ViewBuilder private var control: some View {
      if def.stepped {
        stepped
      } else {
        let span = def.max - def.min
        RotaryKnob(
          spec: KnobSpec(
            label: def.name, format: { [def] fraction in Self.display(def, def.min + fraction * span) }),
          value: span == 0 ? 0 : max(0, min(1, (value - def.min) / span)), tint: tint,
          rest: span == 0 ? nil : (def.defaultValue - def.min) / span, diameter: diameter,
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
          .minimumScaleFactor(0.7)
          .truncationMode(.tail)
          .frame(maxWidth: RackLayout.cellWidth - 6)
      }
      .frame(maxWidth: RackLayout.cellWidth)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(def.name)
      .accessibilityValue(label(current))
    }

    /// A value in words, guessed from its range as the reference guesses it: thousands are hertz,
    /// three orders of magnitude inside ten are seconds, a range across ±12 is signed semitones.
    nonisolated static func display(_ def: ParamDef, _ value: Double) -> String {
      if def.max > 1000 {
        return value >= 1000 ? RackDisplay.fixed(value / 1000, 2) + "k" : "\(Int(RackDisplay.jsRound(value)))"
      }
      if def.max <= 10, def.min >= 0.0001, def.max / max(def.min, 1e-6) > 100 {
        return value < 0.1 ? "\(Int(RackDisplay.jsRound(value * 1000)))ms" : RackDisplay.fixed(value, 2) + "s"
      }
      if def.min <= -12, def.max >= 12 {
        let whole = Int(value.rounded())
        return whole > 0 ? "+\(whole)" : "\(whole)"
      }
      return RackDisplay.fixed(value, 2)
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
