import DriftboxCanvas
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxShell
import Testing

/// A Combinator's routing on a touchscreen: on a phone a sheet across the foot, the rack above it
/// the whole width, the keys away while it is open; every part a finger's height; and its ends,
/// which a desktop types, dragged, a drag one step of undo.
@MainActor
struct RackRoutingTouchTests {
  /// A Combinator routed to an oscillator, and a keyboard, with the routing open.
  static func rack(size: SIMD2<Float> = RackTouchTests.phone) -> RackInterface {
    let rack = RackSession()
    rack.open(
      Patch(
        modules: [
          PatchModule(id: "keys", type: "midi"), PatchModule(id: "c", type: "combi"),
          PatchModule(id: "osc", type: "vco"),
        ], cables: []),
      name: "Routing")
    rack.addRoute("c")
    rack.editRoutes("c")
    let face = RackInterface(rack: rack)
    face.touch = true
    face.size = size
    return face
  }

  @Test func onAPhoneItIsASheetAcrossTheFoot() throws {
    let face = Self.rack()
    let stage = face.stage
    let routing = try #require(stage.routing)
    #expect(routing.sheet)
    #expect(routing.frame.width > 300 && routing.frame.maxY <= RackTouchTests.phone.y)
    #expect(stage.area.width == RackTouchTests.phone.x, "the rack the whole width above it")
    #expect(stage.area.maxY <= routing.frame.y)
    #expect(stage.keyboard == nil && stage.keysChip == nil, "the keys away while it is open")
    let row = try #require(routing.rows.first)
    for part in [row.source, row.module, row.knob, row.min, row.max, row.remove, routing.close] {
      #expect(part.height >= 32, "a finger's height")
    }
    // Closed, the keys come back.
    RackTouchTests.tap(face, RackInterfaceTests.centre(routing.close))
    #expect(face.stage.routing == nil && face.stage.keyboard != nil)
  }

  /// An end dragged up goes up its target's range; the whole drag one step of undo; and a tap
  /// starts no typing, which a touchscreen has no keys for.
  @Test func anEndIsDragged() throws {
    let face = Self.rack()
    let rack = face.rack
    let row = try #require(face.stage.routing?.rows.first)
    let to = rack.patch.modulation[0].to
    let type = try #require(rack.patch.modules.first { $0.id == to.module }?.type)
    let def = try #require(RackSession.routable(type).first { $0.id == to.port })
    RackTouchTests.tap(face, RackInterfaceTests.centre(row.min))
    #expect(!face.takesText)
    let from = RackInterfaceTests.centre(row.max)
    RackTouchTests.finger(face, .began, 1, from)
    RackTouchTests.finger(face, .moved, 1, from - SIMD2(0, 40))
    RackTouchTests.finger(face, .moved, 1, from + SIMD2(0, 85))
    RackTouchTests.finger(face, .ended, 1, from + SIMD2(0, 85))
    let max = try #require(rack.patch.modulation[0].max)
    #expect(abs(max - (def.max - (def.max - def.min) * 0.5)) < 1e-6, "down half the travel from its limit")
    rack.undo()
    #expect(rack.patch.modulation.count == 1, "the routing still there")
    #expect(rack.patch.modulation[0].max == nil, "the whole drag one step")
  }

  /// A tablet keeps it down the right, at a finger's size; a desktop, as it was.
  @Test func aTabletKeepsItBeside() throws {
    let face = Self.rack(size: SIMD2(1280, 800))
    let routing = try #require(face.stage.routing)
    #expect(!routing.sheet && routing.frame.width < 320)
    #expect(try #require(routing.rows.first).max.height >= 32)
    face.touch = false
    let desk = try #require(face.stage.routing)
    #expect(!desk.sheet && desk.rows.first?.max.height == 20)
  }
}
