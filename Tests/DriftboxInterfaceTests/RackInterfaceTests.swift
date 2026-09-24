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
      let pressed = face.buttons.compactMap(\.press?.param) + face.cells.compactMap(\.param?.id)
      #expect(Set(controls + pressed) == shows, "\(type)")
      #expect(controls.count == Set(controls).count, "\(type): each once")
      // Buttons may sit on the screen, as a scale's keys do; nothing else may, nor on each other.
      let parts = face.controls.map(\.cell) + face.buttons.map(\.frame) + face.cells.map(\.frame)
      let screen = face.screen.map { [$0] } ?? []
      func apart(_ a: Rect, _ b: Rect) -> Bool {
        a.maxX <= b.x || b.maxX <= a.x || a.maxY <= b.y || b.maxY <= a.y
      }
      for (index, part) in (parts + screen).enumerated() {
        #expect(face.frame.contains(SIMD2(part.x, part.y)), "\(type)")
        #expect(face.frame.contains(SIMD2(part.maxX - 1, part.maxY - 1)), "\(type)")
        guard index < parts.count else { continue }
        for other in parts[(index + 1)...] {
          #expect(apart(part, other), "\(type): \(part) and \(other) overlap")
        }
      }
      for part in face.controls.map(\.cell) + face.cells.map(\.frame) {
        #expect(screen.allSatisfy { apart(part, $0) }, "\(type): \(part) is on the screen")
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

  static func data(_ face: RackInterface, _ slot: String) -> [Double] {
    face.rack.patch.modules[0].data[slot] ?? []
  }

  /// A tracker's step is clicked on and off and dragged for its value, one drag one undo; a lane's
  /// tag moves its mode on; and a pattern longer than a bar is shown a bar at a time.
  @Test func theTrackerIsWrittenStepByStep() throws {
    let (rack, _) = try Self.alone("tracker")
    rack.rack.set("m", "length", to: 16)
    rack.rack.set("m", "pattern", to: 0)
    var stage = rack.stage
    var face = stage.faces[0]
    #expect(face.cells.count == 64)
    Self.press(rack, Self.window(stage, Self.centre(face.cells[0].frame)))
    #expect(Self.data(rack, "lane1").first == 7)
    #expect(rack.rack.undoTitle == "Undo Edit Step")
    Self.press(rack, Self.window(stage, Self.centre(face.cells[0].frame)))
    #expect(Self.data(rack, "lane1").first == 0, "and off again")

    let step = Self.window(stage, Self.centre(face.cells[1].frame))
    Self.press(rack, step, to: step - SIMD2(0, RackInterface.cellStep * 3 * stage.scale))
    #expect(Self.data(rack, "lane1")[1] == 3)
    rack.rack.undo()
    #expect(Self.data(rack, "lane1")[1] == 0, "one drag, one undo")

    let tag = try #require(face.buttons.first { $0.label == "S1" })
    Self.press(rack, Self.window(stage, Self.centre(tag.frame)))
    #expect(rack.stage.faces[0].buttons.contains { $0.label == "U1" })

    rack.rack.set("m", "length", to: 32)
    stage = rack.stage
    face = stage.faces[0]
    let second = try #require(face.buttons.first { $0.press == .page(1) })
    Self.press(rack, Self.window(stage, Self.centre(second.frame)))
    face = rack.stage.faces[0]
    #expect(face.words.hasSuffix("bar 2/2"))
    #expect(face.cells.first?.index == 16)
  }

  /// An arranger's pattern steps on when clicked, and its bars are dragged; a section written past
  /// the end of the song so far lands where it was clicked.
  @Test func theArrangerIsWrittenSectionBySection() throws {
    let (rack, face) = try Self.alone("arranger")
    let stage = rack.stage
    #expect(face.cells.count == 32)
    Self.press(rack, Self.window(stage, Self.centre(face.cells[6].frame)))
    let patterns = Self.data(rack, "patterns")
    #expect(patterns.count == 16 && patterns[3] == 1)
    let bars = Self.window(stage, Self.centre(face.cells[1].frame))
    Self.press(rack, bars, to: bars - SIMD2(0, RackInterface.cellStep * 2 * stage.scale))
    let repeats = Self.data(rack, "repeats")
    #expect(repeats.count == 16 && repeats[0] == 6 && repeats[1] == 4)
    #expect(rack.rack.undoTitle == "Undo Edit Song")
  }

  /// A key of the scale's keyboard takes the map to Custom and turns its note over.
  @Test func theScaleIsCustomisedFromItsKeys() throws {
    let (rack, face) = try Self.alone("scale-player")
    rack.rack.set("m", "key", to: 0)
    rack.rack.set("m", "scale", to: 0)
    let stage = rack.stage
    let sharp = try #require(stage.faces[0].buttons.first { $0.label == "C#" })
    #expect(!sharp.isOn && face.buttons.count == 12)
    Self.press(rack, Self.window(stage, Self.centre(sharp.frame)))
    #expect(Self.data(rack, "customScale") == [1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1])
    let scale = try #require(RackModules.registry["scale-player"]?.params.first { $0.id == "scale" })
    #expect(rack.rack.value(rack.rack.patch.modules[0], scale) == 13)
  }

  /// An echo's pulse is muted and unmuted by a click; one past the repeat count does nothing.
  @Test func theEchoesAreMutedOneByOne() throws {
    let (rack, _) = try Self.alone("note-echo")
    rack.rack.set("m", "repeats", to: 4)
    let stage = rack.stage
    let face = stage.faces[0]
    #expect(face.buttons.count == 17)
    Self.press(rack, Self.window(stage, Self.centre(face.buttons[2].frame)))
    let steps = Self.data(rack, "steps")
    #expect(steps.count == 17 && steps[2] == 0 && steps[1] == 1)
    #expect(face.buttons[9].press == nil)
    Self.press(rack, Self.window(stage, Self.centre(face.buttons[9].frame)))
    #expect(Self.data(rack, "steps") == steps)
  }

  /// The Chord Loom names the chord a setting voices, and Alter is heard while it is held and let
  /// go of with the press.
  @Test func theChordLoomVoicesItsChord() throws {
    let (rack, _) = try Self.alone("chord-player")
    rack.rack.set("m", "key", to: 0)
    rack.rack.set("m", "scale", to: 0)
    rack.rack.set("m", "notes", to: 3)
    let stage = rack.stage
    let face = stage.faces[0]
    #expect(face.name == "Chord Loom")
    #expect(face.buttons.prefix(3).map(\.label) == ["C", "E", "G"])
    #expect(face.buttons[3].label == "—" && !face.buttons[3].isOn)
    let alter = try #require(face.buttons.first { $0.label == "ALTER" })
    let def = try #require(RackModules.registry["chord-player"]?.params.first { $0.id == "alter" })
    let at = Self.window(stage, Self.centre(alter.frame))
    rack.pointer(PointerEvent(phase: .began, location: at))
    #expect(rack.rack.value(rack.rack.patch.modules[0], def) == 1, "heard from the press")
    #expect(rack.stage.faces[0].buttons[1].label == "D#", "a major third, minor")
    rack.pointer(PointerEvent(phase: .ended, location: at + SIMD2(0, 200)))
    #expect(rack.rack.value(rack.rack.patch.modules[0], def) == 0, "let go of wherever the pointer is")
  }

  /// An Arp's step rests and plays again by a click, the figure moving on past it; one past the
  /// pattern's length does nothing.
  @Test func theArpsStepsRest() throws {
    let (rack, _) = try Self.alone("arp")
    rack.rack.set("m", "patternLength", to: 8)
    let stage = rack.stage
    let face = stage.faces[0]
    #expect(face.buttons.count == 16)
    Self.press(rack, Self.window(stage, Self.centre(face.buttons[1].frame)))
    let pattern = Self.data(rack, "pattern")
    #expect(pattern.count == 16 && pattern[1] == 0)
    let rested = rack.stage.faces[0]
    #expect(rested.buttons[1].label == "—")
    #expect(rested.buttons[2].label == face.buttons[1].label, "the figure holds through a rest")
    #expect(face.buttons[12].press == nil)
  }

  /// A Combinator's rotary turns in whole steps and says so as a percentage; its buttons toggle;
  /// and a learn chip waits for a controller until pressed again.
  @Test func theCombinatorsControls() throws {
    let (rack, face) = try Self.alone("combi")
    let stage = rack.stage
    let rotary = try #require(face.controls.first { $0.param.id == "rotary1" })
    #expect(rotary.whole && rotary.display?(127) == "100%")
    guard case .knob(let dial) = rotary.kind else { throw Unexpected() }
    let at = Self.window(stage, Self.centre(dial))
    Self.press(rack, at, to: at - SIMD2(0, 13))
    let value = rack.rack.value(rack.rack.patch.modules[0], rotary.param)
    #expect(value == value.rounded() && value > 64)

    let pad = try #require(face.buttons.first { $0.label == "2" })
    Self.press(rack, Self.window(stage, Self.centre(pad.frame)))
    let button = try #require(RackModules.registry["combi"]?.params.first { $0.id == "button2" })
    #expect(rack.rack.value(rack.rack.patch.modules[0], button) == 1)

    let chip = try #require(face.buttons.first { $0.press == .learn(param: "rotary3") })
    #expect(chip.label == "learn")
    Self.press(rack, Self.window(stage, Self.centre(chip.frame)))
    #expect(rack.rack.ccLearning == PortReference("m", "rotary3"))
    #expect(rack.stage.faces[0].buttons.contains { $0.label == "turn one…" })
    Self.press(rack, Self.window(stage, Self.centre(chip.frame)))
    #expect(rack.rack.ccLearning == nil)
  }

  /// A mono sine in a temporary WAV file of 16-bit samples.
  static func wav(seconds: Double = 1, rate: Double = 48000, name: String = "Sine.wav") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    var body = Data()
    for i in 0..<Int(seconds * rate) {
      let value = Int16(12000 * sin(2 * Double.pi * 220 * Double(i) / rate))
      withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) }
    }
    var file = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    file.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + body.count))
    file.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(UInt32(rate))
    u32(UInt32(rate) * 2)
    u16(2)
    u16(16)
    file.append(contentsOf: Array("data".utf8))
    u32(UInt32(body.count))
    file.append(body)
    try file.write(to: url)
    return url
  }

  /// Until `done` says so, the main actor let go of between looks: a load finishes off it.
  static func until(_ done: () -> Bool) async throws {
    for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
  }

  /// An empty Slice Lab asks for a file from its screen and its button; one dropped on it loads,
  /// and then its slices are played from, stepped round, and the sample taken to be so many bars.
  @Test func theSliceLabLoadsAndSlices() async throws {
    let (rack, face) = try Self.alone("sampler")
    let stage = rack.stage
    #expect(face.name == "Slice Lab" && face.words == "empty" && face.light == false)
    let prompt = try #require(face.buttons.first { if case .prompt = $0.style { true } else { false } })
    #expect(prompt.frame == face.screen)
    Self.press(rack, Self.window(stage, Self.centre(prompt.frame)))
    #expect(rack.takeFileRequest() == "m" && rack.takeFileRequest() == nil)
    #expect(!rack.takesSeveral("m"))

    let url = try Self.wav()
    #expect(rack.drop([url], at: Self.window(stage, Self.centre(face.frame))))
    try await Self.until { rack.rack.samples["m"] != nil }
    let loaded = rack.stage.faces[0]
    #expect(loaded.words == "sample ready" && loaded.light == true)
    rack.rack.set("m", "slices", to: 8)
    let sliced = rack.stage.faces[0]
    let slices = sliced.buttons.filter { if case .slice = $0.style { true } else { false } }
    #expect(slices.count == 8)
    Self.press(rack, Self.window(rack.stage, Self.centre(slices[2].frame)))
    let slice = try #require(RackModules.registry["sampler"]?.params.first { $0.id == "slice" })
    #expect(rack.rack.value(rack.rack.patch.modules[0], slice) == 2)
    rack.rack.set("m", "slice", to: 0)
    let down = try #require(rack.stage.faces[0].buttons.first { $0.label == "‹" })
    Self.press(rack, Self.window(rack.stage, Self.centre(down.frame)))
    #expect(rack.rack.value(rack.rack.patch.modules[0], slice) == 7, "stepped round, not stopped")

    let eight = try #require(rack.stage.faces[0].buttons.first { $0.press == .sampleBars(8) })
    Self.press(rack, Self.window(rack.stage, Self.centre(eight.frame)))
    #expect(rack.rack.samples["m"]?.bars == 8)
  }

  /// An audio track takes a recording dropped on it, and its start is dragged as a bar and a step.
  @Test func anAudioTrackIsPlaced() async throws {
    let (rack, face) = try Self.alone("audio-track")
    let stage = rack.stage
    #expect(rack.drop([try Self.wav()], at: Self.window(stage, Self.centre(face.frame))))
    try await Self.until { rack.rack.tracks["m"] != nil }
    #expect(rack.stage.faces[0].buttons.allSatisfy { if case .prompt = $0.style { false } else { true } })

    let start = try #require(RackModules.registry["audio-track"]?.params.first { $0.id == "start" })
    let bar = try #require(face.cells.first { $0.caption == "BAR" })
    let at = Self.window(stage, Self.centre(bar.frame))
    Self.press(rack, at, to: at - SIMD2(0, bar.step * 2 * stage.scale))
    #expect(rack.rack.value(rack.rack.patch.modules[0], start) == 32, "bar 3, step 1")
    let step = try #require(rack.stage.faces[0].cells.first { $0.caption == "STEP" })
    let from = Self.window(rack.stage, Self.centre(step.frame))
    Self.press(rack, from, to: from - SIMD2(0, step.step * 4 * stage.scale))
    #expect(rack.rack.value(rack.rack.patch.modules[0], start) == 36, "bar 3, step 5")
    rack.rack.undo()
    #expect(rack.rack.value(rack.rack.patch.modules[0], start) == 32, "one drag, one undo")
  }

  /// A file dropped on a module that holds no recordings is not the rack's.
  @Test func aDropOnAnythingElseIsNotTheRacks() throws {
    let face = Self.rack()
    let osc = try #require(face.stage.faces.first { $0.module.id == "osc" })
    #expect(
      !face.drop(
        [URL(fileURLWithPath: "C:/nowhere.wav")], at: Self.window(face.stage, Self.centre(osc.frame))))
    #expect(!face.drop([URL(fileURLWithPath: "C:/nowhere.wav")], at: SIMD2(5, 5)))
  }

  struct Unexpected: Error {}
}
