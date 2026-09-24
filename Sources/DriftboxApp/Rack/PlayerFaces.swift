#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxRack
  import DriftboxRackSession
  import SwiftUI

  // The Chord Player's, the Arp's and the Combinator's faces: the first two show what they will
  // play — the chord a setting voices, the figure an Arp walks — and the Combinator what each of
  // its controls drives.

  /// The Chord Loom: the eight voices of the chord a setting makes, named, with an Alter button
  /// that holds while it is held.
  struct ChordPlayerFace: View {
    let face: FaceContext
    static let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    nonisolated static let knobs = [
      "key", "scale", "notes", "inversion", "open", "octUp", "octDown", "color",
    ]

    @State private var holding = false

    var body: some View {
      let key = max(0, min(11, Int(face.value("key").rounded())))
      let scale = max(0, min(13, Int(face.value("scale").rounded())))
      let notes = max(1, min(5, Int(face.value("notes").rounded())))
      let inversion = max(0, min(4, Int(face.value("inversion").rounded())))
      let altered = face.value("alter") >= 0.5
      let scaleName =
        ModuleFace.byType["chord-player"]?.labels["scale"].flatMap { scale < $0.count ? $0[scale] : nil }
        ?? "Scale \(scale + 1)"
      let chord = RackPreview.chord(
        .init(
          key: key, scale: scale, custom: face.data("customScale"), notes: notes, inversion: inversion,
          open: face.value("open") >= 0.5, octUp: face.value("octUp") >= 0.5,
          octDown: face.value("octDown") >= 0.5,
          color: face.value("color") >= 0.5, alter: altered))
      PanelTitle(name: "Chord Loom", mark: "CP—8") {
        Text("\(Self.notes[key]) \(scaleName) · \(chord.count) voices".uppercased())
          .font(Theme.mono(8)).tracking(0.4).foregroundStyle(Theme.three.opacity(0.8)).lineLimit(1)
      }
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            RadialGradient(
              colors: [
                Color(red: 94 / 255, green: 48 / 255, blue: 12 / 255).opacity(0.42),
                Color(red: 8 / 255, green: 5 / 255, blue: 3 / 255).opacity(0.97),
              ],
              center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 280)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.three.opacity(0.25)))
        HStack(spacing: 5) {
          ForEach(0..<8, id: \.self) { lane in
            voice(lane, note: lane < chord.count ? chord[lane] : nil, key: key)
          }
        }
        .padding(.init(top: 9, leading: 10, bottom: 27, trailing: 10))
        .frame(maxHeight: .infinity)
        HStack {
          Text("\(notes) TERTIAN").frame(maxWidth: .infinity, alignment: .leading)
          Text("ALTER")
            .font(Theme.mono(7)).tracking(0.8)
            .foregroundStyle(altered ? Color(red: 33 / 255, green: 16 / 255, blue: 0) : Theme.three)
            .padding(.horizontal, 12).frame(height: 18)
            .background(Capsule().fill(altered ? Theme.three : Theme.three.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Theme.three.opacity(0.56)))
            .shadow(color: altered ? Theme.three.opacity(0.58) : .clear, radius: 5)
            .contentShape(Capsule())
            .gesture(
              DragGesture(minimumDistance: 0)
                // Held and let go as one gesture, so a press is one step of undo, not two.
                .onChanged { _ in
                  guard !holding else { return }
                  holding = true
                  face.model.turn(face.module.id, "alter", to: 1)
                }
                .onEnded { _ in
                  holding = false
                  face.model.turn(face.module.id, "alter", to: 0)
                  face.endGesture()
                }
            )
            .accessibilityLabel("Hold to alter chord")
            .accessibilityAddTraits(.isButton)
          Text(inversion == 0 ? "ROOT POSITION" : "INVERSION \(inversion)").frame(
            maxWidth: .infinity, alignment: .trailing)
        }
        .font(Theme.mono(7)).tracking(0.3).foregroundStyle(Theme.dim)
        .padding(.horizontal, 10).padding(.bottom, 4)
      }
      .frame(height: 96)
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: 4), spacing: 0
      ) {
        ForEach(Self.knobs, id: \.self) { id in
          face.control(id, tint: id == "key" ? Theme.three : id == "scale" ? Theme.nine : nil)
        }
      }
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) { Rectangle().fill(Theme.three.opacity(0.12)).frame(height: 1) }
    }

    private func voice(_ lane: Int, note: Int?, key: Int) -> some View {
      let octave = note.map { Int((Double($0 - key) / 12).rounded(.down)) }
      let badge = octave.map { $0 == 0 ? "root" : $0 > 0 ? "+\($0)×" : "\($0)×" } ?? "idle"
      return ZStack {
        UnevenRoundedRectangle(
          topLeadingRadius: 12, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 12
        )
        .fill(
          note == nil
            ? AnyShapeStyle(Theme.three.opacity(0.025))
            : AnyShapeStyle(
              LinearGradient(
                colors: [Color(red: 1, green: 225 / 255, blue: 160 / 255), Theme.three], startPoint: .top,
                endPoint: .bottom)))
        UnevenRoundedRectangle(
          topLeadingRadius: 12, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 12
        )
        .strokeBorder(
          note == nil
            ? Theme.three.opacity(0.1) : Color(red: 1, green: 200 / 255, blue: 107 / 255).opacity(0.92))
        VStack(spacing: 0) {
          Text("\(lane + 1)").font(Theme.mono(6)).opacity(0.62).padding(.top, 4)
          Spacer()
          Text(note.map { Self.notes[(($0 % 12) + 12) % 12] } ?? "—").font(Theme.mono(12, .medium))
          Spacer()
          Text(badge).font(Theme.mono(6)).lineLimit(1).padding(.bottom, 5)
        }
        .foregroundStyle(
          note == nil
            ? Color(red: 1, green: 236 / 255, blue: 203 / 255).opacity(0.23)
            : Color(red: 36 / 255, green: 18 / 255, blue: 3 / 255))
      }
      .shadow(color: note == nil ? .clear : Theme.three.opacity(0.34), radius: 5)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: note)
    }
  }

  /// The Arp Field: sixteen rhythm steps, each showing the figure's note it would play — a click
  /// rests it — over every one of the Arp's controls.
  struct ArpFace: View {
    let face: FaceContext
    static let steps = 16
    nonisolated static let knobs = [
      "enable", "source", "chord", "octaves", "mode", "gate", "hold", "shift", "velocityMode", "velocity",
      "timing", "division", "rate", "patternLength", "insert", "singleRepeat", "shuffle",
    ]

    var body: some View {
      let source = max(0, min(1, Int(face.value("source").rounded())))
      let enabled = face.value("enable") >= 0.5
      let chord = max(0, min(7, Int(face.value("chord").rounded())))
      let mode = max(0, min(5, Int(face.value("mode").rounded())))
      let hold = face.value("hold") >= 0.5
      let timing = max(0, min(2, Int(face.value("timing").rounded())))
      let division = max(0, min(15, Int(face.value("division").rounded())))
      let rate = max(0.1, min(250, face.value("rate")))
      let patternLength = max(1, min(Self.steps, Int(face.value("patternLength").rounded())))
      let insert = max(0, min(4, Int(face.value("insert").rounded())))
      let sourceName = name("source", source, source == 0 ? "Root" : "Played")
      let modeName = name("mode", mode, "Mode \(mode + 1)")
      let timingName =
        timing == 0
        ? "external clock"
        : timing == 1
          ? "\(name("division", division, "division \(division + 1)")) tempo"
            + (face.value("shuffle") >= 0.5 ? " · shuffle" : "")
          : (rate < 10 ? RackDisplay.fixed(rate, 1) : "\(Int(RackDisplay.jsRound(rate)))") + " Hz"
      let stored = face.data("pattern")
      let pattern = (0..<Self.steps).map { $0 < stored.count ? stored[$0] : 1 }
      let figure = RackPreview.arp(
        source: source, chord: chord, octaves: Int(face.value("octaves").rounded()), mode: mode,
        shift: Int(face.value("shift").rounded()), insert: insert)
      let preview: [RackPreview.ArpStep] = {
        var at = 0
        return pattern.map { on in
          let step = figure[min(figure.count - 1, at)]
          if on >= 0.5 { at += 1 }
          return step
        }
      }()
      let played = source == 1
      let tint = played ? Theme.nine : Theme.violet
      PanelTitle(name: "Arp Field", mark: "AP—64") {
        Text(
          (enabled ? "\(sourceName) · \(modeName) · \(timingName)" : "\(sourceName) · converter").uppercased()
        )
        .font(Theme.mono(8)).tracking(0.4).foregroundStyle(tint.opacity(0.82)).lineLimit(1)
      }
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            RadialGradient(
              colors: played
                ? [
                  Color(red: 15 / 255, green: 58 / 255, blue: 54 / 255).opacity(0.58),
                  Color(red: 4 / 255, green: 9 / 255, blue: 10 / 255).opacity(0.98),
                ]
                : [
                  Color(red: 32 / 255, green: 24 / 255, blue: 68 / 255).opacity(0.7),
                  Color(red: 5 / 255, green: 4 / 255, blue: 10 / 255).opacity(0.98),
                ],
              center: UnitPoint(x: 0.5, y: 1.2), startRadius: 0, endRadius: 280)
          )
          .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.25)))
        HStack(spacing: 3) {
          ForEach(0..<Self.steps, id: \.self) { index in
            step(
              index, preview[index], on: pattern[index] >= 0.5, active: index < patternLength, tint: tint,
              pattern: pattern)
          }
        }
        .padding(.init(top: 10, leading: 10, bottom: 28, trailing: 10))
        .frame(maxHeight: .infinity)
        HStack {
          Text(
            source == 0
              ? "\(name("chord", chord, "Chord \(chord + 1)")) intervals".uppercased() : "HELD INPUT LANES"
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          Text(
            (!enabled
              ? "bypass"
              : hold
                ? "hold"
                : face.value("singleRepeat") < 0.5
                  ? "single once" : insert == 0 ? "live" : "insert \(name("insert", insert, "\(insert)"))")
              .uppercased()
          )
          .foregroundStyle(
            hold && enabled ? Color(red: 28 / 255, green: 18 / 255, blue: 3 / 255) : Theme.nine
          )
          .padding(.horizontal, 8).padding(.vertical, 1)
          .background(Capsule().fill(hold && enabled ? Theme.three : .clear))
          .overlay(Capsule().strokeBorder(hold && enabled ? Theme.three : Theme.violet.opacity(0.2)))
          Text(
            "\(patternLength) STEPS · "
              + (face.value("velocityMode") >= 0.5
                ? "\(Int(RackDisplay.jsRound(face.value("velocity") * 100)))% FIXED" : "PLAYED VELOCITY")
          )
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Theme.mono(7)).tracking(0.3).foregroundStyle(Theme.dim)
        .padding(.horizontal, 10).padding(.bottom, 5)
      }
      .frame(height: 94)
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(RackLayout.cellWidth), spacing: 0), count: 7), spacing: 0
      ) {
        ForEach(Self.knobs, id: \.self) { id in
          face.control(
            id, tint: id == "source" || id == "hold" ? Theme.three : id == "mode" ? Theme.nine : nil)
        }
      }
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) { Rectangle().fill(Theme.violet.opacity(0.12)).frame(height: 1) }
    }

    /// A selector's word for its setting, from the Arp's own labels.
    private func name(_ id: String, _ index: Int, _ fallback: String) -> String {
      ModuleFace.byType["arp"]?.labels[id].flatMap { index < $0.count ? $0[index] : nil } ?? fallback
    }

    private func step(
      _ index: Int, _ step: RackPreview.ArpStep, on: Bool, active: Bool, tint: Color, pattern: [Double]
    ) -> some View {
      Button {
        var next = pattern
        next[index] = on ? 0 : 1
        face.setData("pattern", next, "Edit Rhythm")
        face.endGesture()
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 4)
            .fill(
              on
                ? AnyShapeStyle(
                  LinearGradient(
                    colors: [tint.opacity(0.2), tint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color(red: 8 / 255, green: 6 / 255, blue: 14 / 255).opacity(0.72)))
          RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(on ? 0.18 : 0.08))
          // Above the root octave a warm line along the top; below it a pink one along the bottom.
          if on && step.octave > 0 {
            Rectangle().fill(Theme.three.opacity(0.22)).frame(height: 3).frame(
              maxHeight: .infinity, alignment: .top)
          } else if on && step.octave < 0 {
            Rectangle().fill(Theme.eight.opacity(0.2)).frame(height: 3).frame(
              maxHeight: .infinity, alignment: .bottom)
          }
          VStack(spacing: 0) {
            Text("\(index + 1)").font(Theme.mono(5)).foregroundStyle(Theme.dim).padding(.top, 4)
            Spacer()
            Text(on ? step.label : "—").font(Theme.mono(7, .medium))
              .foregroundStyle(on ? Theme.ink.opacity(0.9) : tint.opacity(0.32))
            Spacer()
            Text(on ? (step.octave == 0 ? "root" : "\(step.octave > 0 ? "+" : "")\(step.octave)×") : "rest")
              .font(Theme.mono(5)).foregroundStyle(Theme.dim).padding(.bottom, 4)
          }
          .lineLimit(1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .disabled(!active)
      .opacity(active ? 1 : 0.28)
      .accessibilityLabel("Step \(index + 1)")
      .accessibilityValue(on ? step.label : "rest")
    }
  }

  /// A control's MIDI learn, in the one small chip there is room for: `learn`, then `turn one…`
  /// while it waits for a controller, then the controller it learnt. Clicking an armed chip
  /// disarms it; shift-clicking, or its menu, forgets what it learnt, which re-learning cannot.
  struct LearnChip: View {
    let model: RackSession
    let module: String
    let param: String
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var dim = false

    var body: some View {
      let arming = model.ccLearning == PortReference(module, param)
      let bound = RackCC.bindings(model.ccBindings, for: module)[param]
      Button {
        if NSEvent.modifierFlags.contains(.shift) {
          model.clearCcBinding(module, param)
        } else if arming {
          model.cancelCcLearn()
        } else {
          model.startCcLearn(module, param)
        }
      } label: {
        Text(arming ? "turn one…" : bound.map(RackCC.describe) ?? "learn")
          .font(Theme.mono(8.5))
          .lineLimit(1)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .foregroundStyle(arming ? Theme.ground : bound != nil ? Theme.nine : Theme.dim)
          .background(RoundedRectangle(cornerRadius: 4).fill(arming ? Theme.three : .clear))
          .overlay(
            RoundedRectangle(cornerRadius: 4).strokeBorder(
              arming ? Theme.three : bound != nil ? Theme.nine.opacity(0.4) : Theme.edge)
          )
          // Armed, it pulses: the instruction is to go and touch the hardware, and something
          // has to still be saying so when the eyes come back.
          .opacity(arming && dim ? 0.45 : 1)
      }
      .buttonStyle(.plain)
      .onChange(of: arming, initial: true) { _, arming in
        guard arming, !still else {
          dim = false
          return
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
      }
      .contextMenu {
        if let bound {
          Button("Forget \(RackCC.describe(bound))") { model.clearCcBinding(module, param) }
        }
        Button(bound == nil ? "Learn a Controller" : "Learn Another Controller") {
          model.startCcLearn(module, param)
        }
      }
      .help(
        bound.map { "\(RackCC.describe($0)) — click to learn another, shift-click to forget" }
          ?? "Click, then turn a knob on your controller"
      )
      .accessibilityLabel("MIDI learn")
      .accessibilityValue(arming ? "waiting for a controller" : bound.map(RackCC.describe) ?? "none")
    }
  }

  /// The Combinator: four rotaries and four buttons, what each drives, and the whole routing,
  /// written out, underneath.
  struct CombinatorFace: View {
    let face: FaceContext
    static let controls = 4

    var body: some View {
      let routes = face.model.patch.modulation.filter { $0.from.module == face.module.id }
      PanelTitle(
        name: "Combinator",
        words: routes.isEmpty ? "no routing" : "\(routes.count) routing\(routes.count == 1 ? "" : "s")")
      VStack(spacing: 6) {
        HStack(alignment: .top) {
          ForEach(1...Self.controls, id: \.self) { index in
            let id = "rotary\(index)"
            VStack(spacing: 0) {
              RotaryKnob(
                spec: KnobSpec(
                  label: "Rotary \(index)", format: { "\(Int(RackDisplay.jsRound($0 * 100)))%" }),
                value: face.value(id) / 127, tint: Theme.three, rest: 64 / 127, diameter: 34,
                live: { face.model.turn(face.module.id, id, to: RackDisplay.jsRound($0 * 127)) },
                commit: { value in
                  face.model.set(face.module.id, id, to: RackDisplay.jsRound(value * 127))
                })
              Text(doing(id, routes))
                .font(Theme.mono(10))
                .foregroundStyle(live(id, routes) ? Theme.nine : Theme.dim)
              LearnChip(model: face.model, module: face.module.id, param: id)
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
          }
        }
        HStack(spacing: 8) {
          ForEach(1...Self.controls, id: \.self) { index in
            let id = "button\(index)"
            let on = Int(face.value(id).rounded()) == 1
            Button {
              face.set(id, on ? 0 : 1)
            } label: {
              ZStack(alignment: .topTrailing) {
                Text("\(index)").font(Theme.mono(12)).frame(maxWidth: .infinity, minHeight: 28)
                if live(id, routes) {
                  Circle().fill(Theme.nine).frame(width: 5, height: 5).padding(5)
                }
              }
            }
            .buttonStyle(OptionStyle(on: on, tint: Theme.three))
            .help(
              routes.contains { $0.from.port == id }
                ? "Drives \(routes.filter { $0.from.port == id }.count)" : "Not routed to anything yet")
          }
        }
        // The whole routing, written out: as long as it is, scrolling within the module.
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 2) {
            if routes.isEmpty {
              Text("Nothing routed yet.").font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
            ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
              HStack(spacing: 8) {
                Text(
                  route.from.port.hasPrefix("button")
                    ? "B\(route.from.port.dropFirst(6))" : "R\(route.from.port.dropFirst(6))"
                )
                .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.three).frame(
                  width: 22, alignment: .leading)
                Text(describe(route.to)).font(Theme.mono(9)).foregroundStyle(Theme.ink.opacity(0.8))
                  .lineLimit(1)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        let open = face.model.editingRoutes == face.module.id
        Button(open ? "Close Routing" : "Routing…") {
          face.model.editRoutes(open ? nil : face.module.id)
        }
        .buttonStyle(OptionStyle(on: open, tint: Theme.nine))
        .help("Edit which knobs each rotary and button drives, and between what")
      }
      .padding(.horizontal, 4)
    }

    private func patched(_ id: String) -> Bool {
      face.model.patch.cables.contains { $0.from.module == face.module.id && $0.from.port == id }
    }

    private func live(_ id: String, _ routes: [ModRoute]) -> Bool {
      routes.contains { $0.from.port == id } || patched(id)
    }

    /// `→ 3`, `→ 3 +` when it is patched as well, `patched`, or nothing.
    private func doing(_ id: String, _ routes: [ModRoute]) -> String {
      let count = routes.filter { $0.from.port == id }.count
      if count > 0 { return patched(id) ? "→ \(count) +" : "→ \(count)" }
      return patched(id) ? "patched" : "—"
    }

    private func describe(_ to: PortReference) -> String {
      let type = face.model.patch.modules.first { $0.id == to.module }?.type
      let name = type.flatMap { RackModules.registry[$0]?.params.first { $0.id == to.port }?.name }
      return "\(to.module) · \(name ?? to.port)"
    }
  }
#endif
