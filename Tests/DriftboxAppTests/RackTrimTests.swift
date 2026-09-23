#if canImport(AVFoundation)
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The trim pot beside every inlet: what turning one does to the patch, to undo and to the
  /// sound, and how the back panel reads and writes it.
  @MainActor
  struct RackTrimTests {
    /// A free-running VCO straight into an Out.
    static func model() -> RackModel {
      let model = RackModel()
      model.open(
        Patch(
          modules: [PatchModule(id: "osc", type: "vco"), PatchModule(id: "out", type: "out")],
          cables: [PatchCable(from: PortReference("osc", "out"), to: PortReference("out", "in"))]),
        name: "Test")
      return model
    }

    @Test func aTrimIsHeldToItsRangeAndUnityIsNoTrim() {
      let model = Self.model()
      #expect(model.trim("out", "in") == 1)
      model.setTrim("out", "in", to: 0.4)
      #expect(model.patch.modules[1].inputTrims["in"] == 0.4)
      model.setTrim("out", "in", to: -3)
      #expect(model.trim("out", "in") == -1)
      model.setTrim("out", "in", to: .nan)
      #expect(model.patch.modules[1].inputTrims.isEmpty)
      // Only a module's own inlets have pots.
      model.setTrim("out", "nowhere", to: 0.5)
      model.setTrim("gone", "in", to: 0.5)
      #expect(model.patch.modules[1].inputTrims.isEmpty)
    }

    @Test func oneDragOfAPotIsOneUndo() {
      let model = Self.model()
      model.setTrim("out", "in", to: 0.8)
      model.setTrim("out", "in", to: 0.5)
      model.setTrim("out", "in", to: 0.2)
      model.endTurn()
      #expect(model.undoTitle == "Undo Set Input Trim")
      model.undo()
      #expect(model.trim("out", "in") == 1)
      #expect(!model.canUndo)
    }

    /// Heard: a pot off unity gets a slot of its own in the plan, and turning it within its
    /// travel reaches the sound through that slot; back at unity, the slot goes.
    @Test func aTrimIsHeard() {
      let model = Self.model()
      model.listen()
      let frames = 4800
      let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      defer {
        left.deallocate()
        right.deallocate()
      }
      func loudness() -> Float {
        model.host.render(frames: frames, left: left, right: right)
        model.host.render(frames: frames, left: left, right: right)
        return (0..<frames).reduce(0) { max($0, abs(left[$1])) }
      }
      let full = loudness()
      #expect(full > 0.01)
      #expect(model.host.plan?.inputTrims["out"]?["in"] == nil)
      model.setTrim("out", "in", to: 0.5)
      #expect(model.host.plan?.inputTrims["out"]?["in"] != nil)
      #expect(abs(loudness() - full / 2) < full * 0.05)
      // Within its travel: the same plan, the new value through the slot.
      let plan = model.host.plan?.inputTrims
      model.setTrim("out", "in", to: 0)
      #expect(model.host.plan?.inputTrims == plan)
      #expect(loudness() == 0)
      model.setTrim("out", "in", to: 1)
      model.endTurn()
      #expect(model.host.plan?.inputTrims["out"]?["in"] == nil)
      #expect(abs(loudness() - full) < full * 0.05)
    }

    @Test func thePotReadsAsTheReferencesDoes() {
      #expect(BackPanel.trimText(0.55) == "0.55×")
      #expect(BackPanel.trimText(-0.3) == "−0.30×")
      #expect(BackPanel.trimText(1) == "1.00×")
      #expect(BackPanel.trimStep(0.554) == 0.55)
      #expect(BackPanel.trimStep(1.7) == 1)
      #expect(BackPanel.trimStep(-1.2) == -1)
      #expect(BackPanel.potAngle(0) == 0)
      #expect(abs(BackPanel.potAngle(1) - 135 * .pi / 180) < 1e-12)
      #expect(abs(BackPanel.potAngle(-1) + 135 * .pi / 180) < 1e-12)
    }
  }
#endif
