import DriftboxCanvas
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Testing

/// The rack for fingers: kept as a desktop draws it, and moved about instead — fitted to the phone's
/// width, pinched to zoom, slid on its panels to pan, a module double-tapped to fill the width at a
/// finger's size — with a header that fits a phone, and controls a finger takes from as far off as
/// it can be expected to miss by.
@MainActor
struct RackTouchTests {
  static let phone = SIMD2<Float>(372, 828)

  /// A rack of `count` oscillators, a keyboard and an Out, long enough to scroll on a phone.
  static func rack(oscillators count: Int = 1) -> RackInterface {
    let rack = RackSession()
    var modules = [PatchModule(id: "keys", type: "midi")]
    modules += (0..<count).map { PatchModule(id: "osc\($0)", type: "vco") }
    modules.append(PatchModule(id: "out", type: "out"))
    rack.open(
      Patch(
        modules: modules,
        cables: [PatchCable(from: PortReference("osc0", "out"), to: PortReference("out", "in"))]),
      name: "Test")
    let face = RackInterface(rack: rack)
    face.touch = true
    face.size = phone
    return face
  }

  static func finger(_ face: RackInterface, _ phase: PointerEvent.Phase, _ id: Int, _ at: SIMD2<Float>) {
    face.pointer(PointerEvent(phase: phase, id: id, kind: .touch, location: at))
  }

  static func tap(_ face: RackInterface, _ at: SIMD2<Float>, id: Int = 1) {
    finger(face, .began, id, at)
    finger(face, .ended, id, at)
  }

  static func drag(_ face: RackInterface, from: SIMD2<Float>, to: SIMD2<Float>, id: Int = 1) {
    finger(face, .began, id, from)
    for step in 1...5 { finger(face, .moved, id, from + (to - from) * Float(step) / 5) }
    finger(face, .ended, id, to)
  }

  /// Somewhere on `module`'s panel that is none of its controls.
  static func panel(_ face: RackInterface, _ module: String) throws -> SIMD2<Float> {
    let stage = face.stage
    let found = try #require(stage.faces.first { $0.module.id == module })
    return RackInterfaceTests.window(stage, SIMD2(found.frame.x + 6, found.frame.y + 6))
  }

  @Test func onAPhoneTheRackFitsTheWidthAndTheHeaderFits() throws {
    let face = Self.rack()
    let stage = face.stage
    #expect(stage.touch && stage.zoom == 1)
    for placed in stage.faces {
      let left = RackInterfaceTests.window(stage, SIMD2(placed.frame.x, 0)).x
      let right = RackInterfaceTests.window(stage, SIMD2(placed.frame.maxX, 0)).x
      #expect(left >= 0 && right <= Self.phone.x, "\(placed.module.id) inside the screen")
    }
    // Every chip on the screen, none over another, and the patch's name the one at the left.
    let chips = stage.chips
    #expect(chips.map(\.target) == [.patches, .run, .flip, .add])
    #expect(chips.allSatisfy { $0.frame.x >= stage.header.x && $0.frame.maxX <= stage.header.maxX })
    for (a, b) in zip(chips, chips.dropFirst()) { #expect(a.frame.maxX <= b.frame.x) }
    #expect(stage.tempo.x >= chips[1].frame.maxX && stage.tempo.maxX <= chips[2].frame.x)
    #expect(chips[0].frame.width >= 60, "room for a name")
    // A desktop's is as it was.
    let desk = RackInterfaceTests.rack()
    #expect(desk.stage.chips.map(\.target) == [.run, .flip, .add] && !desk.stage.touch)
  }

  /// A finger on a panel, away from its controls, slides the rack; on a knob, it turns the knob.
  @Test func aFingerOnAPanelPansAndOnAKnobTurnsIt() throws {
    let face = Self.rack(oscillators: 24)
    #expect(face.stage.maxScroll > 0)
    let from = try Self.panel(face, "osc2")
    Self.drag(face, from: from, to: from - SIMD2(0, 200))
    #expect(face.scroll > 150, "slid up the rack")
    let stage = face.stage
    // A knob in view, now the rack has moved.
    let shown = stage.faces.flatMap { placed in placed.controls.map { (placed, $0) } }.first { _, control in
      guard case .knob(let dial) = control.kind else { return false }
      return stage.area.contains(RackInterfaceTests.window(stage, RackInterfaceTests.centre(dial)))
    }
    let (placed, control) = try #require(shown)
    guard case .knob(let dial) = control.kind else { return }
    let before = face.rack.patch.modules.first { $0.id == placed.module.id }?.params[control.param.id]
    let at = RackInterfaceTests.window(stage, RackInterfaceTests.centre(dial))
    let scrolled = face.scroll
    Self.drag(face, from: at, to: at - SIMD2(0, 60))
    #expect(face.scroll == scrolled, "the knob turned, not the rack")
    #expect(face.rack.patch.modules.first { $0.id == placed.module.id }?.params[control.param.id] != before)
  }

  /// A finger on a knob that goes sideways pans the rack and leaves the knob as it was; one that goes
  /// up turns it.
  @Test func sidewaysFromAKnobPans() throws {
    let face = Self.rack(oscillators: 8)
    face.fit("osc2")
    let stage = face.stage
    #expect(stage.maxPan > 0, "zoomed wider than the screen")
    let placed = try #require(stage.faces.first { $0.module.id == "osc2" })
    let knob = try #require(placed.controls.first { if case .knob = $0.kind { true } else { false } })
    guard case .knob(let dial) = knob.kind else { return }
    let start = RackInterfaceTests.window(stage, RackInterfaceTests.centre(dial))
    let pan = face.pan
    Self.drag(face, from: start, to: start + SIMD2(120, 4))
    #expect(face.pan != pan, "the rack slid sideways")
    #expect(
      face.rack.patch.modules.first { $0.id == "osc2" }?.params[knob.param.id] == nil, "the knob untouched")
    // Up from the same knob turns it.
    let now = face.stage
    let again = try #require(now.faces.first { $0.module.id == "osc2" })
    guard case .knob(let moved) = again.controls.first(where: { $0.param.id == knob.param.id })?.kind else {
      return
    }
    let from = RackInterfaceTests.window(now, RackInterfaceTests.centre(moved))
    Self.drag(face, from: from, to: from - SIMD2(2, 60))
    #expect(face.rack.patch.modules.first { $0.id == "osc2" }?.params[knob.param.id] != nil, "turned")
  }

  /// A finger that lands a little off a small control, drawn small at the whole rack's width, still
  /// takes it: a finger's reach is kept whatever the zoom.
  @Test func aNearMissTakesTheControl() throws {
    let face = Self.rack()
    let stage = face.stage
    let (_, control) = try #require(
      RackInterfaceTests.control(stage) { if case .knob = $0 { true } else { false } })
    guard case .knob(let dial) = control.kind else { return }
    let edge = RackInterfaceTests.window(stage, SIMD2(dial.maxX, dial.y + dial.height / 2))
    let off = edge + SIMD2(RackStage.reach - 4, 0)
    guard case .knob = stage.target(at: off) else {
      Issue.record("\(RackStage.reach - 4) points off the dial is still the knob")
      return
    }
  }

  /// A double tap fills the width with a module, at a finger's size; another puts the rack back.
  @Test func aDoubleTapFitsAModule() throws {
    let face = Self.rack(oscillators: 8)
    let at = try Self.panel(face, "osc1")
    Self.tap(face, at)
    Self.tap(face, at)
    #expect(face.fitted == "osc1")
    let stage = face.stage
    let fitted = try #require(stage.faces.first { $0.module.id == "osc1" })
    let left = RackInterfaceTests.window(stage, SIMD2(fitted.frame.x, fitted.frame.y))
    let right = RackInterfaceTests.window(stage, SIMD2(fitted.frame.maxX, 0)).x
    #expect(
      abs(left.x - RackStage.inset) < 8 && abs(right - (Self.phone.x - RackStage.inset)) < 8, "the width")
    #expect(abs(left.y - stage.area.y) < 8, "at the top")
    if case .knob(let dial) = fitted.controls.first(where: { if case .knob = $0.kind { true } else { false } }
    )?.kind {
      #expect(dial.width * stage.scale >= 44, "a knob a finger's size")
    }
    let again = try Self.panel(face, "osc1")
    Self.tap(face, again)
    Self.tap(face, again)
    #expect(face.fitted == nil && face.zoom == 1)
  }

  /// A module's title is the module's: a double tap on it fits the module, however near a control is.
  @Test func aDoubleTapOnATitleFitsItsModule() throws {
    let face = Self.rack(oscillators: 8)
    let stage = face.stage
    let placed = try #require(stage.faces.first { $0.module.id == "osc2" })
    let title = RackInterfaceTests.window(stage, SIMD2(placed.title.maxX - 4, placed.title.maxY))
    #expect(stage.target(at: title) == .module("osc2"))
    Self.tap(face, title)
    Self.tap(face, title)
    #expect(face.fitted == "osc2")
  }

  /// A module the rack's whole width already fills, double-tapped, is zoomed until its knobs are a
  /// finger's size, the part tapped staying under the finger.
  @Test func aDoubleTapZoomsAWideModuleToAFingersSize() throws {
    let rack = RackSession()
    rack.open(
      Patch(modules: [PatchModule(id: "seq", type: "seq"), PatchModule(id: "out", type: "out")], cables: []),
      name: "Wide")
    let face = RackInterface(rack: rack)
    face.touch = true
    face.size = Self.phone
    var stage = face.stage
    let placed = try #require(stage.faces.first { $0.module.id == "seq" })
    #expect(placed.span == 2, "a full-width module")
    let at = RackInterfaceTests.window(stage, SIMD2(placed.frame.maxX - 30, placed.title.maxY))
    let under = stage.design(at)
    Self.tap(face, at)
    Self.tap(face, at)
    #expect(face.fitted == "seq")
    stage = face.stage
    #expect(RackTouchTests.knobDiameter * stage.scale >= 43.9, "a knob a finger's size")
    let now = RackInterfaceTests.window(stage, under)
    #expect(abs(now.x - at.x) < 1, "the part tapped under the finger")
  }

  static let knobDiameter: Float = 34

  /// Two fingers pinch the rack bigger or smaller about the point between them, which stays put.
  @Test func twoFingersZoomAboutTheirMiddle() throws {
    let face = Self.rack(oscillators: 8)
    let middle = SIMD2<Float>(186, 400)
    let under = face.stage.design(middle)
    Self.finger(face, .began, 1, middle - SIMD2(40, 0))
    Self.finger(face, .began, 2, middle + SIMD2(40, 0))
    Self.finger(face, .moved, 1, middle - SIMD2(80, 0))
    Self.finger(face, .moved, 2, middle + SIMD2(80, 0))
    #expect(abs(face.zoom - 2) < 0.01)
    let stage = face.stage
    let now = RackInterfaceTests.window(stage, under)
    #expect(
      abs(now.x - middle.x) < 1 && abs(now.y - middle.y) < 1, "the rack under the fingers stays under them")
    Self.finger(face, .ended, 1, middle - SIMD2(80, 0))
    Self.finger(face, .moved, 2, middle)
    Self.finger(face, .ended, 2, middle)
    #expect(abs(face.zoom - 2) < 0.01, "the finger left behind neither pans nor presses")
    #expect(face.rack.selection.isEmpty)
  }

  /// On the back a finger from a jack draws a cable, as a mouse does; on a bay it pans, and a module
  /// is moved from its menu instead.
  @Test func onTheBackAJackPatchesAndABayPans() throws {
    let face = Self.rack(oscillators: 24)
    face.rack.flip()
    let stage = face.stage
    let jacks = RackLayout.jacks(stage.placements)
    let from = try #require(jacks.first { $0.module == "keys" && $0.port == "gate" })
    let to = try #require(jacks.first { $0.module == "osc1" && $0.port == "pitch" })
    let cables = face.rack.patch.cables.count
    Self.drag(
      face, from: RackInterfaceTests.window(stage, SIMD2(Float(from.x), Float(from.y))),
      to: RackInterfaceTests.window(stage, SIMD2(Float(to.x), Float(to.y))))
    #expect(face.rack.patch.cables.count == cables + 1)
    let order = face.rack.patch.modules.map(\.id)
    let bay = try #require(stage.placements.first { $0.id == "osc3" })
    let start = RackInterfaceTests.window(stage, SIMD2(Float(bay.x) + 60, Float(bay.y) + 4))
    Self.drag(face, from: start, to: start - SIMD2(0, 150))
    #expect(face.rack.patch.modules.map(\.id) == order, "nothing moved")
    #expect(face.scroll > 100, "the rack slid")
  }

  /// The patch's name is its menu: the patches, and the way back to the groovebox.
  @Test func thePatchNameIsThePatchesMenu() throws {
    let face = Self.rack()
    var back = false
    face.showGroovebox = { back = true }
    let chip = try #require(face.stage.chips.first { $0.target == .patches })
    Self.tap(face, RackInterfaceTests.centre(chip.frame))
    let menu = try #require(face.takeMenuRequest()?.menu)
    #expect(menu.title == "Test")
    face.choose("rack.groovebox")
    #expect(back)
    Self.tap(face, RackInterfaceTests.centre(chip.frame))
    _ = face.takeMenuRequest()
    let entry = try #require(PatchEntry.all.first)
    face.choose("patch." + entry.id)
    #expect(face.rack.name == entry.name)
  }

  /// A face waiting for a file asks a finger to tap its screen, which a phone can, rather than to
  /// drop a file on it, which it cannot; and the tap asks for one. A desktop's still asks for a drop.
  @Test func anEmptyFaceAsksForATap() throws {
    let asks = [
      "sampler": "Tap to choose a sample", "audio-track": "Tap to choose a recording",
      "multisampler": "Tap to choose an instrument set",
    ]
    for (type, words) in asks {
      let (desktop, _) = try RackInterfaceTests.alone(type)
      let rack = desktop.rack
      let face = RackInterface(rack: rack)
      face.touch = true
      face.size = Self.phone
      let stage = face.stage
      let prompt = try #require(
        stage.faces.first?.buttons.first { if case .prompt = $0.style { true } else { false } })
      #expect(prompt.label == words, "\(type)")
      Self.tap(face, RackInterfaceTests.window(stage, RackInterfaceTests.centre(prompt.frame)))
      #expect(face.takeFileRequest() == "m", "\(type)")
      let dropped = try #require(
        desktop.stage.faces.first?.buttons.first { if case .prompt = $0.style { true } else { false } })
      #expect(dropped.label.hasPrefix("Drop"), "\(type)")
    }
  }

  /// A tablet draws the rack no larger than a desktop does, centred, upright or on its side, which
  /// is still a finger's size for a knob: fitted to its width it would be a poster of a module or
  /// two. A phone's is fitted to its width. A finger zooms either past that.
  @Test func aTabletDrawsTheRackNoLargerThanADesktop() {
    let face = Self.rack()
    for size in [TabletLayoutTests.upright, TabletLayoutTests.onItsSide] {
      face.size = size
      let stage = face.stage
      let drawn = Float(RackLayout.width) * stage.scale
      #expect(stage.scale == 1.35 && stage.maxPan == 0, "\(size)")
      #expect(34 * stage.scale >= 44, "a knob a finger's size")
      let left = stage.origin.x - stage.area.x
      let right = stage.area.maxX - (stage.origin.x + drawn)
      #expect(abs(left - right) < 0.5 && left > RackStage.inset, "centred, \(size)")
      face.fit("osc0")
      #expect(face.stage.scale > 1.35)
      face.fitRack()
    }
    face.size = Self.phone
    #expect(face.stage.scale < 1.35 && face.stage.origin.x == RackStage.inset, "fitted to the width")
  }

  /// A chip in the header or over the keys takes a finger anywhere up and down its strip, as tall as
  /// a finger where the chip is 28 points; a desktop's takes a click on the chip alone.
  @Test func aChipTakesAFingerAlongItsStrip() throws {
    let face = Self.rack()
    face.size = TabletLayoutTests.upright
    face.keysShown = true
    let stage = face.stage
    let add = try #require(stage.chips.first { $0.target == .add })
    let above = SIMD2(add.frame.x + add.frame.width / 2, stage.header.y + 2)
    #expect(!add.frame.contains(above) && stage.target(at: above) == .add)
    let keyboard = try #require(stage.keyboard)
    let over = SIMD2(keyboard.hide.x + keyboard.hide.width / 2, keyboard.frame.y + 2)
    #expect(!keyboard.hide.contains(over) && stage.target(at: over) == .keys)

    let desktop = RackStage(rack: face.rack, size: TabletLayoutTests.upright)
    let chip = try #require(desktop.chips.first { $0.target == .add })
    #expect(desktop.target(at: SIMD2(chip.frame.x + chip.frame.width / 2, desktop.header.y + 2)) == nil)
  }
}
