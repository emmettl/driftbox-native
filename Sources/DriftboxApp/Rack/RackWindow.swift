#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxRack
  import SwiftUI

  /// The rack's window: a header with the patch, the transport, the side showing and a way to
  /// add a module, over the rack itself, which turns round to show its back. The typing keys
  /// play it — two octaves from `z` and `q`, with `,` and `.` for the octave — space starts and
  /// stops its transport, and tab turns it round.
  public struct RackWindow: View {
    let model: RackModel
    let attach: () -> Void

    @State private var octave = 0
    @State private var held: [Character: Int] = [:]
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active

    public init(model: RackModel, attach: @escaping () -> Void) {
      self.model = model
      self.attach = attach
    }

    public var body: some View {
      VStack(spacing: 0) {
        RackHeader(model: model, octave: octave)
        RackStage(model: model)
      }
      .background(Theme.ground)
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onKeyPress(phases: [.down, .up, .repeat]) { press in keyPress(press) }
      .onAppear {
        attach()
        focused = true
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
        // A key held as the window loses focus never sends its key-up.
        held = [:]
        model.allNotesOff()
      }
      .focusedSceneValue(\.rack, model)
      // MIDI from a controller plays the rack while this is the window in front.
      .onChange(of: active, initial: true) { model.inFront = active == .key }
    }

    private func keyPress(_ press: KeyPress) -> KeyPress.Result {
      guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
      if press.key == .tab {
        if press.phase == .down { model.flip() }
        return .handled
      }
      if press.key == .space {
        if press.phase == .down { model.toggleRunning() }
        return .handled
      }
      guard let character = press.characters.lowercased().first else { return .ignored }
      if let semitone = RackKeyboard.keyMap[character] {
        switch press.phase {
        case .down:
          let note = RackKeyboard.root + semitone + octave * 12
          held[character] = note
          model.noteDown(note)
        case .up:
          if let note = held.removeValue(forKey: character) { model.noteUp(note) }
        default:
          break
        }
        return .handled
      }
      guard press.phase == .down else { return .ignored }
      switch character {
      case ",": octave = max(-2, octave - 1)
      case ".": octave = min(3, octave + 1)
      default: return .ignored
      }
      return .handled
    }
  }

  extension FocusedValues {
    /// The rack, while its window is the one in front: what the Edit menu undoes in.
    @Entry var rack: RackModel?
  }

  /// The rack's header.
  struct RackHeader: View {
    let model: RackModel
    let octave: Int
    @State private var adding = false

    var body: some View {
      HStack(spacing: 10) {
        PatchMenu(model: model)
        Spacer(minLength: 8)
        Button {
          model.toggleRunning()
        } label: {
          Label(model.running ? "Stop" : "Play", systemImage: model.running ? "stop.fill" : "play.fill")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.chip(on: model.running, tint: Theme.live))
        .help("Start or stop the rack's transport (space)")
        DragNumber(
          label: "BPM", value: model.tempo, range: 20...300, perPoint: 0.5, format: { "\(Int($0.rounded()))" }
        ) { model.setTempo($0) }
        Rectangle().fill(Theme.edge).frame(width: 1, height: 18)
        Text("keys C\(2 + octave)")
          .font(Theme.mono(10)).foregroundStyle(Theme.dim)
          .help("The typing keys play the rack from z and q; , and . change the octave")
        Button {
          model.flip()
        } label: {
          Label(model.flipped ? "Front" : "Back", systemImage: "arrow.left.arrow.right")
        }
        .buttonStyle(.chip(on: model.flipped, tint: Theme.three))
        .help("Turn the rack round to patch its cables (tab)")
        Button {
          adding = true
        } label: {
          Label("Add", systemImage: "plus")
        }
        .buttonStyle(.chip)
        .popover(isPresented: $adding, arrowEdge: .bottom) {
          ModulePicker { type in
            adding = false
            model.add(type)
          }
        }
      }
      .padding(.horizontal, 16)
      .frame(height: 48)
      .background(Theme.panel)
      .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
  }

  /// The factory patches, by kind, and what is open now.
  struct PatchMenu: View {
    let model: RackModel

    var body: some View {
      Menu {
        let kinds: [(String?, String)] = [
          ("start", "Start Here"), ("study", "Studies"), ("song", "Songs"), ("input", "Input"),
        ]
        ForEach(kinds, id: \.1) { kind, title in
          let entries = PatchEntry.all.filter { $0.category == kind }
          if !entries.isEmpty {
            Section(title) {
              ForEach(entries) { entry in
                Button(entry.name) { model.open(entry) }
              }
            }
          }
        }
        let others = PatchEntry.all.filter { entry in !kinds.contains { $0.0 == entry.category } }
        if !others.isEmpty {
          Section("More") {
            ForEach(others) { entry in Button(entry.name) { model.open(entry) } }
          }
        }
      } label: {
        HStack(spacing: 6) {
          FieldLabel("Patch")
          Text(model.name).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.ink)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
        }
      }
      // A button-styled menu draws the whole label; a borderless one keeps only its first text.
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// Every module this build can make, on its shelf, each card with its picture and its line.
  struct ModulePicker: View {
    let choose: (String) -> Void
    @State private var search = ""

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        TextField("Find a module", text: $search)
          .textFieldStyle(.roundedBorder)
          .font(Theme.mono(12))
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(ModuleFace.shelves, id: \.name) { shelf in
              let types = shelf.types.filter(matches)
              if !types.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  FieldLabel(shelf.name)
                  LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                    ForEach(types, id: \.self) { type in card(type) }
                  }
                }
              }
            }
          }
        }
      }
      .padding(12)
      .frame(width: 520, height: 520)
      // The rack's own dark, not the system's pale popover.
      .environment(\.colorScheme, .dark)
      .presentationBackground(Theme.ground)
    }

    private func matches(_ type: String) -> Bool {
      guard !search.isEmpty else { return true }
      let name = RackModules.registry[type]?.name ?? type
      let blurb = ModuleFace.byType[type]?.blurb ?? ""
      return name.localizedCaseInsensitiveContains(search) || blurb.localizedCaseInsensitiveContains(search)
    }

    private func card(_ type: String) -> some View {
      let face = ModuleFace.byType[type]
      let accent = ModuleFace.accent(face?.group)
      return Button {
        choose(type)
      } label: {
        HStack(alignment: .top, spacing: 8) {
          ModuleLogo(paths: face?.logo?.paths ?? [], colour: accent)
            .frame(width: 48, height: 30)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
          VStack(alignment: .leading, spacing: 2) {
            Text(RackModules.registry[type]?.name ?? type)
              .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(face?.blurb ?? "")
              .font(.system(size: 9.5)).foregroundStyle(Theme.dim).lineLimit(3)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(CardStyle())
      .help(face?.blurb ?? "")
    }
  }

  struct CardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0.04))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.edge))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
  }

  /// A module's picture: strokes in a 64 × 40 box, drawn at whatever size it is given.
  struct ModuleLogo: View {
    let paths: [String]
    let colour: Color

    var body: some View {
      Canvas { context, size in
        let scale = min(size.width / 64, size.height / 40)
        context.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 40 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        for d in paths {
          context.stroke(
            SVGPath.parse(d), with: .color(colour),
            style: StrokeStyle(lineWidth: 2 / scale, lineCap: .round, lineJoin: .round))
        }
      }
    }
  }

  /// The rack itself, scaled to the window's width, turning round from front to back.
  struct RackStage: View {
    let model: RackModel

    var body: some View {
      GeometryReader { geometry in
        let layout = RackLayout.layout(model.patch.modules)
        // About the reference's size, a little larger when there is room: past this the panels
        // stop reading as a rack of modules and start reading as a poster of one.
        let scale = max(1, min(1.35, (geometry.size.width - 48) / RackLayout.width))
        ScrollView(.vertical) {
          Flip(flipped: model.flipped) {
            front(layout, scale: scale)
          } back: {
            BackPanel(model: model, layout: layout, scale: scale)
          }
          .frame(width: layout.width * scale, height: max(layout.height, RackLayout.row) * scale)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
      }
    }

    private func front(_ layout: RackLayout.Layout, scale: Double) -> some View {
      ZStack(alignment: .topLeading) {
        // A click on no module lets go of the selection.
        Color.clear.contentShape(Rectangle()).onTapGesture { model.select(nil) }
        ForEach(layout.placements, id: \.id) { placement in
          if let module = model.patch.modules.first(where: { $0.id == placement.id }),
            let def = RackModules.registry[placement.type]
          {
            Faceplate(
              model: model, module: module, def: def, span: placement.span,
              selected: model.selection.contains(placement.id)
            )
            .padding(3)
            .frame(width: placement.width, height: placement.height)
            .contentShape(Rectangle())
            .onTapGesture { model.select(placement.id, adding: NSEvent.modifierFlags.contains(.command)) }
            .contextMenu { menu(for: module) }
            .offset(x: placement.x, y: placement.y)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
          } else {
            Unknown(type: placement.type)
              .padding(3)
              .frame(width: placement.width, height: placement.height)
              .offset(x: placement.x, y: placement.y)
          }
        }
      }
      .frame(width: layout.width, height: max(layout.height, RackLayout.row), alignment: .topLeading)
      .animation(.spring(response: 0.32, dampingFraction: 0.82), value: layout)
      .scaleEffect(scale, anchor: .topLeading)
      .frame(
        width: layout.width * scale, height: max(layout.height, RackLayout.row) * scale,
        alignment: .topLeading)
    }

    @ViewBuilder private func menu(for module: PatchModule) -> some View {
      Button("Move Up") { model.move(module.id, by: -1) }
      Button("Move Down") { model.move(module.id, by: 1) }
      Divider()
      Button(module.bypassed ? "Unbypass" : "Bypass") { model.setBypassed(module.id, !module.bypassed) }
      Button("Duplicate") { model.duplicate(module.id) }
      Divider()
      Button("Remove") { model.remove(module.id) }
    }
  }

  /// A module this build cannot make yet: named, so the patch still says what is in it.
  struct Unknown: View {
    let type: String

    var body: some View {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Theme.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .overlay {
          Text("\(type) — not in this build yet").font(Theme.mono(10)).foregroundStyle(Theme.dim)
        }
    }
  }

  /// Two faces of one thing, turned round about its vertical axis: the front until halfway, the
  /// back after, over half a second with the reference's ease.
  struct Flip<Front: View, Back: View>: View {
    let flipped: Bool
    @ViewBuilder var front: () -> Front
    @ViewBuilder var back: () -> Back

    var body: some View {
      Faces(angle: flipped ? 180 : 0, front: front, back: back)
        .animation(.timingCurve(0.6, 0.05, 0.3, 1, duration: 0.52), value: flipped)
    }

    /// Animatable, so the face that shows can change exactly at the edge-on moment. The back is
    /// turned round once already, so it reads the right way when the whole is turned again.
    struct Faces: View, @preconcurrency Animatable {
      var angle: Double
      let front: () -> Front
      let back: () -> Back

      var animatableData: Double {
        get { angle }
        set { angle = newValue }
      }

      var body: some View {
        let showingBack = angle > 90
        ZStack {
          front()
            .opacity(showingBack ? 0 : 1)
            .allowsHitTesting(!showingBack)
          back()
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            .opacity(showingBack ? 1 : 0)
            .allowsHitTesting(showingBack)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
      }
    }
  }
#endif
