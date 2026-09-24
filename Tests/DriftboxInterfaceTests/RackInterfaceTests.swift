import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Foundation
import Testing

/// The rack drawn on the canvas: where its modules and their controls are, what a press or a drag
/// on each does to the rack, its keys, and its menus.
@MainActor
struct RackInterfaceTests {
  /// A keyboard, a VCO with a range knob and a waveform choice, and an Out: the smallest patch with
  /// a knob, a choice and a stepper to press.
  static func patch() -> Patch {
    Patch(
      modules: [
        PatchModule(id: "keys", type: "midi"), PatchModule(id: "osc", type: "vco"),
        PatchModule(id: "out", type: "out"),
      ],
      cables: [
        PatchCable(from: PortReference("keys", "pitch"), to: PortReference("osc", "pitch")),
        PatchCable(from: PortReference("osc", "out"), to: PortReference("out", "in")),
      ])
  }

  static func rack() -> RackInterface {
    let rack = RackSession()
    rack.open(patch(), name: "Test")
    let face = RackInterface(rack: rack)
    face.size = SIMD2(1000, 700)
    return face
  }

  static func centre(_ rect: Rect) -> SIMD2<Float> {
    SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2)
  }

  /// A point in the rack's design space, on the window.
  static func window(_ stage: RackStage, _ point: SIMD2<Float>) -> SIMD2<Float> {
    stage.origin + point * stage.scale
  }

  /// The first control of `kind` on the rack, and its module.
  static func control(
    _ stage: RackStage, _ matches: (RackStage.Control.Kind) -> Bool
  ) -> (face: RackStage.Face, control: RackStage.Control)? {
    for face in stage.faces {
      if let control = face.controls.first(where: { matches($0.kind) }) { return (face, control) }
    }
    return nil
  }

  static func press(_ face: RackInterface, _ at: SIMD2<Float>, to lift: SIMD2<Float>? = nil) {
    face.pointer(PointerEvent(phase: .began, location: at))
    if let lift { face.pointer(PointerEvent(phase: .moved, location: lift)) }
    face.pointer(PointerEvent(phase: .ended, location: lift ?? at))
  }

  /// Every module is where the rack's layout puts it, scaled into the window under the header, with
  /// a control for every param a hand could set.
  @Test func theModulesAreWhereTheLayoutPutsThem() throws {
    let stage = Self.rack().stage
    let layout = RackLayout.layout(Self.patch().modules)
    #expect(stage.faces.map(\.module.id) == layout.placements.map(\.id))
    for (face, placement) in zip(stage.faces, layout.placements) {
      #expect(face.frame.x == Float(placement.x) + 3 && face.frame.y == Float(placement.y) + 3)
      let shown = RackModules.registry[placement.type]?.params.filter { !$0.hidden }.count
      #expect(face.controls.count == shown, "\(placement.type)")
    }
    #expect(stage.scale == 1.35, "as large as the Mac's rack goes, with room")
    #expect(stage.origin.y == stage.header.maxY + RackStage.margin)
    #expect(stage.chips.map(\.label) == ["PLAY", "BACK", "ADD"])
  }

  /// A knob turns as it is dragged and is heard as it turns, one turn one undo; two presses put it
  /// back where it started life.
  @Test func aKnobTurnsAndIsOneUndo() throws {
    let face = Self.rack()
    let stage = face.stage
    let (module, control) = try #require(Self.control(stage) { if case .knob = $0 { true } else { false } })
    guard case .knob(let dial) = control.kind else { return }
    let def = control.param
    let at = Self.window(stage, Self.centre(dial))
    let from = face.rack.value(module.module, def)
    #expect(stage.target(at: at) == .knob(module: module.module.id, param: def.id))

    Self.press(face, at, to: at - SIMD2(0, 17))
    let turned = try #require(face.rack.patch.modules.first { $0.id == module.module.id })
    let span = def.max - def.min
    let expected = def.min + min(1, (from - def.min) / span + 0.1) * span
    #expect(abs(face.rack.value(turned, def) - expected) < 1e-6 * max(1, abs(span)))
    #expect(face.rack.undoTitle == "Undo Set \(def.name)")
    face.rack.undo()
    #expect(!face.rack.canUndo, "one turn, one undo")
    face.rack.redo()

    Self.press(face, at)
    Self.press(face, at)
    let reset = try #require(face.rack.patch.modules.first { $0.id == module.module.id })
    #expect(face.rack.value(reset, def) == def.defaultValue)
  }

  /// A choice's buttons set it; a stepper steps it, no further than its ends.
  @Test func choicesAreSet() throws {
    let face = Self.rack()
    let stage = face.stage
    if let (module, control) = Self.control(stage, { if case .options = $0 { true } else { false } }),
      case .options(let buttons) = control.kind
    {
      Self.press(face, Self.window(stage, Self.centre(buttons[1])))
      let set = try #require(face.rack.patch.modules.first { $0.id == module.module.id })
      #expect(face.rack.value(set, control.param) == control.param.min + 1)
    }
    if let (module, control) = Self.control(stage, { if case .stepper = $0 { true } else { false } }),
      case .stepper(_, let down, let up) = control.kind
    {
      let from = face.rack.value(module.module, control.param)
      Self.press(face, Self.window(stage, Self.centre(up)))
      var now = try #require(face.rack.patch.modules.first { $0.id == module.module.id })
      #expect(face.rack.value(now, control.param) == min(control.param.max, from.rounded() + 1))
      for _ in 0..<40 { Self.press(face, Self.window(stage, Self.centre(down))) }
      now = try #require(face.rack.patch.modules.first { $0.id == module.module.id })
      #expect(face.rack.value(now, control.param) == control.param.min, "no further than its end")
    }
  }

  /// A press on a module's panel selects it, with Ctrl adds it, and one on no module lets go.
  @Test func aPanelIsSelected() throws {
    let face = Self.rack()
    let stage = face.stage
    let out = try #require(stage.faces.first { $0.module.id == "out" })
    let osc = try #require(stage.faces.first { $0.module.id == "osc" })
    Self.press(face, Self.window(stage, Self.centre(out.title)))
    #expect(face.rack.selection == ["out"])
    face.pointer(
      PointerEvent(phase: .began, location: Self.window(stage, Self.centre(osc.title)), modifiers: .control))
    #expect(face.rack.selection == ["out", "osc"])
    face.pointer(PointerEvent(phase: .ended, location: .zero))
    Self.press(face, SIMD2(5, 690))
    #expect(face.rack.selection.isEmpty)
  }

  /// The header plays and stops the rack, and its tempo is dragged as a number.
  @Test func theHeaderRunsTheRack() throws {
    let face = Self.rack()
    let stage = face.stage
    let run = try #require(stage.chips.first { $0.target == .run })
    Self.press(face, Self.centre(run.frame))
    #expect(face.rack.running)
    #expect(face.stage.chips.first?.label == "STOP")
    let tempo = Self.centre(stage.tempo)
    let from = face.rack.tempo
    Self.press(face, tempo, to: tempo - SIMD2(0, 20))
    #expect(face.rack.tempo == (from + 10).rounded())
    #expect(face.rack.undoTitle == "Undo Set Tempo")
  }

  /// The keys play the rack from `z` and `q`, each lifting the note it played, and `,` and `.` move
  /// them an octave; a key held with Ctrl is a shortcut's.
  @Test func theKeysPlayTheRack() {
    let face = Self.rack()
    #expect(face.key(KeyEvent(key: .character("z"))))
    #expect(face.rack.sounding == [RackKeyboard.root])
    #expect(face.key(KeyEvent(key: .character("z"), isDown: false)))
    #expect(face.rack.sounding.isEmpty)
    #expect(face.key(KeyEvent(key: .character(","))))
    #expect(face.key(KeyEvent(key: .character("q"))))
    #expect(face.rack.sounding == [RackKeyboard.root], "q is an octave up, and the keys an octave down")
    #expect(face.key(KeyEvent(key: .character("q"), isDown: false)))
    #expect(face.rack.sounding.isEmpty)
    #expect(!face.key(KeyEvent(key: .character("z"), modifiers: .control)))
    #expect(!face.key(KeyEvent(key: .character("p"))))
  }

  /// A module's menu moves it, bypasses it, copies it and takes it out; the Add menu offers the
  /// modules by what they are for, and adds one.
  @Test func theMenus() throws {
    let face = Self.rack()
    let stage = face.stage
    let osc = try #require(stage.faces.first { $0.module.id == "osc" })
    let at = Self.window(stage, Self.centre(osc.title))
    let menu = try #require(face.menu(at: at))
    #expect(
      menu.commands.map(\.id) == [
        "module.up", "module.down", "module.bypass", "module.duplicate", "module.remove",
      ])
    face.choose("module.bypass")
    #expect(face.rack.patch.modules[1].bypassed)
    _ = face.menu(at: at)
    face.choose("module.remove")
    #expect(!face.rack.patch.modules.contains { $0.id == "osc" })

    let add = try #require(face.stage.chips.first { $0.target == .add })
    Self.press(face, Self.centre(add.frame))
    let request = try #require(face.takeMenuRequest())
    #expect(face.takeMenuRequest() == nil, "asked for once")
    #expect(!request.menu.items.isEmpty)
    #expect(
      !request.menu.commands.contains { $0.id == "add.plugin" }, "no plug-ins with nothing to make them")
    face.choose("add.noise")
    #expect(face.rack.patch.modules.contains { $0.type == "noise" })
  }

  /// The rack turned round, with its jacks where the layout puts them.
  static func back() -> (RackInterface, RackStage, [RackLayout.Jack]) {
    let face = rack()
    let flip = face.stage.chips.first { $0.target == .flip }!
    press(face, centre(flip.frame))
    let stage = face.stage
    return (face, stage, RackLayout.jacks(stage.placements))
  }

  static func window(_ stage: RackStage, _ jack: RackLayout.Jack) -> SIMD2<Float> {
    window(stage, SIMD2(Float(jack.x), Float(jack.y)))
  }

  /// The header's BACK turns the rack round, and FRONT back again.
  @Test func theRackTurnsRound() throws {
    let (face, stage, _) = Self.back()
    #expect(face.rack.flipped)
    let flip = try #require(stage.chips.first { $0.target == .flip })
    #expect(flip.label == "FRONT" && flip.isOn)
    Self.press(face, Self.centre(flip.frame))
    #expect(!face.rack.flipped)
  }

  /// A cable is drawn from a jack and dropped near another of the other side — either way round —
  /// and lands in it, one undo; dropped on nothing, it is nothing.
  @Test func aCableIsDrawnBetweenJacks() throws {
    let (face, stage, jacks) = Self.back()
    let taken = Set(face.rack.patch.cables.map(\.to))
    let inlet = try #require(
      jacks.first {
        $0.kind == .inlet && $0.module == "out" && !taken.contains(PortReference($0.module, $0.port))
      }
        ?? jacks.first { $0.kind == .inlet && !taken.contains(PortReference($0.module, $0.port)) })
    let outlet = try #require(jacks.first { $0.kind == .outlet && $0.module != inlet.module })
    let cables = face.rack.patch.cables.count

    Self.press(face, Self.window(stage, outlet), to: Self.window(stage, inlet) + SIMD2(8, 6))
    #expect(face.rack.patch.cables.count == cables + 1, "it snaps")
    #expect(
      face.rack.patch.cables.last
        == PatchCable(
          from: PortReference(outlet.module, outlet.port), to: PortReference(inlet.module, inlet.port)))
    #expect(face.rack.undoTitle == "Undo Connect")
    face.rack.undo()

    Self.press(face, Self.window(stage, inlet), to: Self.window(stage, outlet))
    #expect(face.rack.patch.cables.count == cables + 1, "from the inlet end too")
    face.rack.undo()

    Self.press(face, Self.window(stage, outlet), to: Self.window(stage, outlet) + SIMD2(0, 400))
    #expect(face.rack.patch.cables.count == cables)
  }

  /// The × by an inlet a cable is in pulls the cable out.
  @Test func aCableIsPulledOut() throws {
    let (face, stage, jacks) = Self.back()
    let cable = face.rack.patch.cables[1]
    let inlet = try #require(
      RackLayout.jack(in: jacks, module: cable.to.module, port: cable.to.port, kind: .inlet))
    let unplug = RackInterface.unplug(SIMD2(Float(inlet.x), Float(inlet.y)))
    Self.press(face, Self.window(stage, unplug))
    #expect(!face.rack.patch.cables.contains(cable))
    #expect(face.rack.patch.cables.count == 1)
  }

  /// An inlet's trim pot turns as it is dragged down and up, one drag one undo, and two presses
  /// put it back at unity.
  @Test func aTrimPotTurns() throws {
    let (face, stage, jacks) = Self.back()
    let inlet = try #require(jacks.first { $0.kind == .inlet })
    let pot = Self.window(stage, RackInterface.pot(inlet))
    #expect(face.rack.trim(inlet.module, inlet.port) == 1)
    face.pointer(PointerEvent(phase: .began, location: pot))
    face.pointer(PointerEvent(phase: .moved, location: pot + SIMD2(0, 10)))
    face.pointer(PointerEvent(phase: .moved, location: pot + SIMD2(0, 25)))
    face.pointer(PointerEvent(phase: .ended, location: pot + SIMD2(0, 25)))
    #expect(face.rack.trim(inlet.module, inlet.port) == 0.5)
    #expect(face.rack.undoTitle == "Undo Set Input Trim")
    face.rack.undo()
    #expect(face.rack.trim(inlet.module, inlet.port) == 1, "one drag, one undo")
    face.rack.redo()

    face.pointer(PointerEvent(phase: .began, location: pot))
    face.pointer(PointerEvent(phase: .moved, location: pot + SIMD2(0, 10), modifiers: .shift))
    face.pointer(PointerEvent(phase: .ended, location: pot + SIMD2(0, 10)))
    #expect(face.rack.trim(inlet.module, inlet.port) == 0.45, "finer with Shift")

    Self.press(face, pot)
    Self.press(face, pot)
    #expect(face.rack.trim(inlet.module, inlet.port) == 1)
  }

  /// A bay is dragged to another place in the rack, and its module goes there; one only pressed is
  /// selected, and stays where it is.
  @Test func aModuleIsMovedOnTheBack() throws {
    let (face, stage, _) = Self.back()
    let out = try #require(stage.placements.first { $0.id == "out" })
    let first = stage.placements[0]
    let grab = SIMD2(Float(out.x) + 10, Float(out.y) + 10)
    Self.press(face, Self.window(stage, grab))
    #expect(face.rack.selection == ["out"])
    #expect(face.rack.patch.modules.map(\.id) == ["keys", "osc", "out"])

    let to = SIMD2(Float(first.x) + 10, Float(first.y) - 20)
    Self.press(face, Self.window(stage, grab), to: Self.window(stage, to))
    #expect(face.rack.patch.modules.first?.id == "out")
    #expect(face.rack.undoTitle == "Undo Move Module")

    Self.press(face, SIMD2(5, 690))
    #expect(face.rack.selection.isEmpty)
  }

  /// A module with a face of its own, alone in a rack, and its face.
  static func alone(_ type: String) throws -> (RackInterface, RackStage.Face) {
    let rack = RackSession()
    rack.open(Patch(modules: [PatchModule(id: "m", type: type)], cables: []), name: type)
    let face = RackInterface(rack: rack)
    face.size = SIMD2(1000, 700)
    return (face, try #require(face.stage.faces.first))
  }

  /// Each hand-built face lays out what it says it shows, as a control or its buttons, and all of it
  /// fits its panel without landing on anything else.
  @Test func handBuiltFacesShowWhatTheySay() throws {
    for (type, shows) in RackFaces.shows {
      let (_, face) = try Self.alone(type)
      let controls = face.controls.map(\.param.id)
      #expect(Set(controls + face.buttons.map(\.param)) == shows, "\(type)")
      #expect(controls.count == Set(controls).count, "\(type): each once")
      var parts = face.controls.map(\.cell) + face.buttons.map(\.frame)
      if let screen = face.screen { parts.append(screen) }
      for (index, part) in parts.enumerated() {
        #expect(face.frame.contains(SIMD2(part.x, part.y)), "\(type)")
        #expect(face.frame.contains(SIMD2(part.maxX - 1, part.maxY - 1)), "\(type)")
        for other in parts[(index + 1)...] {
          let apart =
            part.maxX <= other.x || other.maxX <= part.x || part.maxY <= other.y || other.maxY <= part.y
          #expect(apart, "\(type): \(part) and \(other) overlap")
        }
      }
    }
    let (_, generic) = try Self.alone("noise")
    #expect(generic.words == RackLayout.portSummary(RackModules.registry["noise"]!))
  }

  /// The VCO names its shape and lets the pulse width sleep while the shape is not a pulse; its tune
  /// knob is the big one.
  @Test func theVCOSaysItsShape() throws {
    let (rack, face) = try Self.alone("vco")
    #expect(face.words == "Saw")
    let width = try #require(face.controls.first { $0.param.id == "width" })
    #expect(width.opacity < 1)
    let tune = try #require(face.controls.first { $0.param.id == "tune" })
    guard case .knob(let dial) = tune.kind else { throw Unexpected() }
    #expect(dial.width == 46)

    rack.rack.set("m", "shape", to: 1)
    let pulse = try #require(rack.stage.faces.first)
    #expect(pulse.words == "Pulse")
    #expect(pulse.controls.first { $0.param.id == "width" }?.opacity == 1)
  }

  /// The ladder says when it starts to sing on its own, in pink.
  @Test func theLadderSquelches() throws {
    let (rack, face) = try Self.alone("ladder")
    #expect(face.words == "4-pole")
    rack.rack.set("m", "resonance", to: 0.9)
    let singing = try #require(rack.stage.faces.first)
    #expect(singing.words == "squelch")
    #expect(singing.controls.first { $0.param.id == "resonance" }?.tint == Theme.eight)
  }

  /// The MIDI module says where its notes come from, and names its channels.
  @Test func theMIDIModuleSaysWhatIsComingIn() throws {
    let (_, face) = try Self.alone("midi")
    #expect(face.words == "keys" && face.wordsTint == nil)
    let channel = try #require(face.controls.first { $0.param.id == "channel" })
    #expect(channel.labels?.first == "Omni" && channel.labels?.count == 17)
  }

  /// The looper's transport sets its mode, one press one undo, and CLEAR turns its param over each
  /// press; the tuner and the meter have their screens.
  @Test func theLooperIsPlayedFromItsTransport() throws {
    let (rack, face) = try Self.alone("looper")
    let stage = rack.stage
    #expect(face.buttons.map(\.label) == ["STOP", "REC", "PLAY", "DUB", "CLEAR"])
    #expect(face.words == "stereo · session" && face.mark == "LS—30")
    #expect(face.buttons[0].isOn)
    Self.press(rack, Self.window(stage, Self.centre(face.buttons[1].frame)))
    let mode = try #require(RackModules.registry["looper"]?.params.first { $0.id == "mode" })
    #expect(rack.rack.value(rack.rack.patch.modules[0], mode) == 1)
    #expect(rack.stage.faces[0].buttons[1].isOn)

    let clear = try #require(RackModules.registry["looper"]?.params.first { $0.id == "clear" })
    let from = rack.rack.value(rack.rack.patch.modules[0], clear)
    Self.press(rack, Self.window(stage, Self.centre(face.buttons[4].frame)))
    let once = rack.rack.value(rack.rack.patch.modules[0], clear)
    #expect(once != from)
    Self.press(rack, Self.window(rack.stage, Self.centre(rack.stage.faces[0].buttons[4].frame)))
    #expect(rack.rack.value(rack.rack.patch.modules[0], clear) == from, "turned back over")

    for type in ["tuner", "meter"] {
      let (_, face) = try Self.alone(type)
      let screen = try #require(face.screen, "\(type)")
      #expect(screen.width > 100 && screen.height > 50, "\(type)")
    }
  }

  struct Unexpected: Error {}
}
