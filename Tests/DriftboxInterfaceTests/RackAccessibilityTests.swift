import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Foundation
import Testing

/// The rack as a screen reader is told it: the header, every module's controls named as its face
/// names them, and the cables on the back; and what it asks done as a hand would do it.
@MainActor
struct RackAccessibilityTests {
  static func node(_ face: RackInterface, _ id: String) throws -> AccessibilityNode {
    try #require(face.accessibility.node(id), "no \(id)")
  }

  /// The header's transport, tempo and Add, and a group for each module, every id once; played,
  /// and the tempo set as one step of undo.
  @Test func theHeaderIsDescribed() throws {
    let face = RackInterfaceTests.rack()
    let root = face.accessibility
    let ids = root.flattened.map(\.id)
    #expect(Set(ids).count == ids.count, "each id once")
    #expect(try Self.node(face, "rack.name").value == "Test")
    let run = try Self.node(face, "rack.run")
    #expect(run.role == .toggle && run.isOn == false)
    let tempo = try Self.node(face, "rack.tempo")
    #expect(tempo.role == .slider && tempo.current == face.rack.tempo && tempo.range == 20...300)
    for module in ["keys", "osc", "out"] {
      let group = try Self.node(face, "module.\(module)")
      #expect(group.role == .group && !group.name.isEmpty && group.frame.z > 0)
    }

    #expect(face.perform(.press("rack.run")))
    #expect(face.rack.running)
    #expect(try Self.node(face, "rack.run").isOn == true, "told as it is now")
    #expect(face.perform(.set("rack.tempo", 133.4)))
    #expect(face.rack.tempo == 133)
    #expect(face.rack.undoTitle == "Undo Set Tempo")
    #expect(!face.perform(.press("module.nowhere.menu")), "nothing there")
  }

  /// A knob set and stepped over its range, and a choice stepped through its words: each one step of
  /// undo, as a hand's turn is.
  @Test func aModulesControlsAreSet() throws {
    let face = RackInterfaceTests.rack()
    let osc = try Self.node(face, "module.osc")
    let sliders = osc.children.filter { $0.role == .slider }
    #expect(!sliders.isEmpty)
    let tune = try Self.node(face, "module.osc.tune")
    let range = try #require(tune.range)
    #expect(face.perform(.set(tune.id, range.upperBound)))
    #expect(try Self.node(face, tune.id).current == range.upperBound)
    #expect(face.rack.canUndo)
    #expect(face.perform(.decrement(tune.id)))
    #expect(try #require(try Self.node(face, tune.id).current) < range.upperBound)

    let shape = try Self.node(face, "module.osc.shape")
    #expect(shape.value == "Saw" && shape.step == 1)
    #expect(face.perform(.increment(shape.id)))
    #expect(try Self.node(face, shape.id).value == "Pulse")
    #expect(face.perform(.set(shape.id, 99)))
    #expect(try Self.node(face, shape.id).value == "Tri", "kept to its choices")

    // A mute is on or off, not a choice between "On" and "Mute".
    let mute = try Self.node(face, "module.out.mute")
    #expect(mute.role == .toggle && mute.isOn == false)
    #expect(face.perform(.press(mute.id)))
    #expect(face.rack.patch.modules.first { $0.id == "out" }?.params["mute"] == 1)
    #expect(try Self.node(face, mute.id).isOn == true)
  }

  /// A face's short words said whole, and controls a face names alike told apart.
  @Test func namesAreSaidWhole() throws {
    let (ladder, _) = try RackInterfaceTests.alone("ladder")
    #expect(try Self.node(ladder, "module.m.resonance").name == "Resonance")
    let (groovebox, _) = try RackInterfaceTests.alone("groovebox")
    let levels = groovebox.accessibility.flattened.filter { $0.id.hasSuffix("-level") }.map(\.name)
    #expect(levels.count == 4 && Set(levels).count == 4, "\(levels)")
  }

  /// Every hand-built face is described whole — each control, button and number on it — and each
  /// is named in words, not a face's marks.
  @Test func everyFaceIsNamedInWords() throws {
    for type in RackFaces.shows.keys.sorted() {
      let (face, built) = try RackInterfaceTests.alone(type)
      let group = try Self.node(face, "module.m")
      let parts = group.children.filter { !$0.id.hasSuffix(".words") && !$0.id.hasSuffix(".menu") }
      #expect(parts.count == built.controls.count + built.buttons.count + built.cells.count, "\(type)")
      for part in group.flattened {
        #expect(part.name.contains { $0.isLetter || $0.isNumber }, "\(type): \(part.id) named \(part.name)")
      }
    }
  }

  /// A tracker's step set as a number, written into its lane; and pressed, turned on or off as a
  /// click does.
  @Test func aTrackersStepIsSet() throws {
    let (face, _) = try RackInterfaceTests.alone("tracker")
    let steps = face.accessibility.flattened.filter { $0.name.hasPrefix("Lane 1 step ") }
    let first = try #require(steps.first)
    #expect(first.name == "Lane 1 step 1" && first.value == "off")
    #expect(face.perform(.set(first.id, 12)))
    #expect(RackInterfaceTests.data(face, "lane1").first == 12)
    #expect(face.perform(.press(first.id)))
    #expect(RackInterfaceTests.data(face, "lane1").first == 0, "a click on a step with a note clears it")
  }

  /// A module's menu, asked for from its head, as the secondary button asks for it.
  @Test func aModulesMenuIsAskedFor() throws {
    let face = RackInterfaceTests.rack()
    #expect(face.perform(.press("module.osc.menu")))
    let request = try #require(face.takeMenuRequest())
    #expect(request.menu.commands.contains { $0.id == "module.bypass" })
  }

  /// Turned round, the cables between the modules, from what to what.
  @Test func theBackTellsOfTheCables() throws {
    let face = RackInterfaceTests.rack()
    #expect(face.perform(.press("rack.flip")))
    #expect(face.rack.flipped)
    let back = try Self.node(face, "back")
    #expect(back.children.count == face.rack.patch.cables.count)
    #expect(back.children.allSatisfy { $0.role == .text && $0.value?.hasPrefix("to ") == true })
    #expect(face.accessibility.node("module.osc") == nil, "the fronts face away")
  }
}
