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
    #expect(stage.chips.map(\.label) == ["PLAY", "ADD"])
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
}
