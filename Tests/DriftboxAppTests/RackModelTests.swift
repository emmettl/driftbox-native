#if canImport(AVFoundation)
  import DriftboxDocument
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The rack's edits, as the reference's store makes them, its undo, and the keys: what each does
  /// to the patch, and that it reaches the sound.
  @MainActor
  struct RackModelTests {
    /// A VCO into an Out, and a keyboard into the VCO.
    static func small() -> Patch {
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

    static func model(_ patch: Patch = small()) -> RackModel {
      let model = RackModel()
      model.open(patch, name: "Test")
      return model
    }

    @Test func itOpensOnAFactoryPatchThatNeedsNothingLoaded() {
      let model = RackModel()
      #expect(model.name == PatchEntry.all.first { $0.id == RackModel.firstPatch }?.name)
      #expect(!model.patch.modules.isEmpty)
    }

    @Test func aSourceArrivesWithAnOutOfItsOwn() throws {
      let model = Self.model()
      let id = try #require(model.add("vco"))
      #expect(id == "vco-1")
      let out = try #require(model.patch.modules.last)
      #expect(out.id == "out-1" && out.type == "out" && out.params["level"] == 0.7)
      #expect(
        model.patch.cables.last
          == PatchCable(from: PortReference(id, "out"), to: PortReference("out-1", "in")))
      #expect(model.selection == [id])
      // Anything else arrives on its own.
      let delay = try #require(model.add("delay"))
      #expect(model.patch.modules.last?.id == delay)
      #expect(model.add("no-such-module") == nil)
    }

    @Test func aCopyGoesBesideItsOriginal() {
      let model = Self.model()
      model.turn("osc", "tune", to: 7)
      model.endTurn()
      model.duplicate("osc")
      #expect(model.patch.modules.map(\.id) == ["keys", "osc", "vco-1", "out"])
      #expect(model.patch.modules[2].params["tune"] == 7)
    }

    @Test func aRemovedModuleTakesItsCablesWithIt() {
      let model = Self.model()
      model.select("osc")
      model.remove("osc")
      #expect(model.patch.modules.map(\.id) == ["keys", "out"])
      #expect(model.patch.cables.isEmpty)
      #expect(model.selection.isEmpty)
    }

    @Test func anInletHoldsOneCable() {
      let model = Self.model()
      // A second VCO, which arrives wired to an Out of its own.
      model.add("vco")
      model.connect(PortReference("vco-1", "out"), PortReference("out", "in"))
      #expect(model.patch.cables.filter { $0.to == PortReference("out", "in") }.count == 1)
      #expect(!model.patch.cables.contains { $0.from == PortReference("osc", "out") })
      // An outlet feeds as many as it likes.
      #expect(model.patch.cables.filter { $0.from == PortReference("vco-1", "out") }.count == 2)
      model.disconnect(PatchCable(from: PortReference("vco-1", "out"), to: PortReference("out", "in")))
      #expect(!model.patch.cables.contains { $0.to == PortReference("out", "in") })
    }

    @Test func modulesMoveByDropAndByStep() {
      let model = Self.model()
      model.drop("out", at: 0)
      #expect(model.patch.modules.map(\.id) == ["out", "keys", "osc"])
      // Dropped where it already is: nothing, and nothing to undo.
      model.drop("out", at: 1)
      model.move("keys", by: 1)
      #expect(model.patch.modules.map(\.id) == ["out", "osc", "keys"])
      model.move("keys", by: 1)
      #expect(model.patch.modules.map(\.id) == ["out", "osc", "keys"])
      model.undo()
      model.undo()
      #expect(model.patch.modules.map(\.id) == ["keys", "osc", "out"])
      #expect(!model.canUndo)
    }

    @Test func oneTurnOfAKnobIsOneUndo() {
      let model = Self.model()
      for value in stride(from: 0.0, through: 12, by: 1) { model.turn("osc", "tune", to: value) }
      model.endTurn()
      model.turn("osc", "tune", to: -5)
      model.endTurn()
      #expect(model.undoTitle == "Undo Set Tune")
      model.undo()
      #expect(model.patch.modules[1].params["tune"] == 12)
      model.undo()
      #expect(model.patch.modules[1].params["tune"] == nil)
      model.redo()
      #expect(model.patch.modules[1].params["tune"] == 12)
      // A new edit forgets what could have been redone.
      model.setBypassed("osc", true)
      #expect(!model.canRedo)
    }

    /// A drag across a pattern is one step of undo, and it reaches the sound without the patch
    /// being rebuilt.
    @Test func oneDragAcrossAPatternIsOneUndo() {
      var patch = Self.small()
      patch.modules.append(PatchModule(id: "seq", type: "tracker", data: ["lane1": [0, 0, 0, 0]]))
      let model = Self.model(patch)
      model.setData("seq", "lane1", to: [7, 0, 0, 0])
      model.setData("seq", "lane1", to: [8, 0, 0, 0])
      model.setData("seq", "lane1", to: [9, 0, 0, 0])
      model.endTurn()
      model.setData("seq", "lane1", to: [9, 0, 0, 0])
      #expect(model.patch.modules[3].data["lane1"] == [9, 0, 0, 0])
      #expect(model.undoTitle == "Undo Edit Pattern")
      model.undo()
      #expect(model.patch.modules[3].data["lane1"] == [0, 0, 0, 0])
      #expect(!model.canUndo)
      model.setData("nobody", "lane1", to: [1])
      #expect(!model.canUndo)
    }

    @Test func theHistoryIsCapped() {
      let model = Self.model()
      for step in 0..<(RackModel.historyLimit + 10) {
        model.set("osc", "tune", to: Double(step % 2 == 0 ? 1 : 2))
      }
      var undone = 0
      while model.canUndo {
        model.undo()
        undone += 1
      }
      #expect(undone == RackModel.historyLimit)
    }

    @Test func openingAPatchForgetsTheOldOnesHistory() throws {
      let model = Self.model()
      model.remove("osc")
      let entry = try #require(PatchEntry.all.first)
      model.open(entry)
      #expect(!model.canUndo)
      #expect(model.name == entry.name)
    }

    @Test func aCableRunningBackwardsIsDrawnAsDelayed() {
      var patch = Self.small()
      patch.modules.append(PatchModule(id: "echo", type: "delay"))
      patch.cables.append(PatchCable(from: PortReference("osc", "out"), to: PortReference("echo", "in")))
      patch.cables.append(PatchCable(from: PortReference("echo", "out"), to: PortReference("echo", "in")))
      let model = Self.model(patch)
      #expect(model.delayed.contains("echo.out>echo.in"))
      #expect(!model.delayed.contains("osc.out>out.in"))
    }

    @Test func freshIdsCountUpPastWhatIsTaken() {
      var patch = Self.small()
      patch.modules.append(PatchModule(id: "vco-1", type: "vco"))
      patch.modules.append(PatchModule(id: "vco-3", type: "vco"))
      #expect(RackModel.freshId(patch, "vco") == "vco-2")
      #expect(RackModel.freshId(patch, "lfo") == "lfo-1")
    }

    @Test func thePatchIsRememberedBetweenLaunches() throws {
      let suite = "rack-model-tests-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }
      let model = RackModel(memory: memory)
      model.open(Self.small(), name: "Small")
      model.set("osc", "tune", to: 3)
      let again = RackModel(memory: memory)
      #expect(again.name == "Small")
      #expect(again.patch == model.patch)
    }

    /// The keys and the knobs reach the sound: a note on the keyboard is heard through the VCO,
    /// and turning the Out down to nothing silences it.
    @Test func keysAndKnobsAreHeard() {
      // The keyboard's gate opening a VCA the VCO runs through.
      let model = Self.model(
        Patch(
          modules: [
            PatchModule(id: "keys", type: "midi"), PatchModule(id: "osc", type: "vco"),
            PatchModule(id: "amp", type: "vca", params: ["gain": 0]), PatchModule(id: "out", type: "out"),
          ],
          cables: [
            PatchCable(from: PortReference("keys", "pitch"), to: PortReference("osc", "pitch")),
            PatchCable(from: PortReference("osc", "out"), to: PortReference("amp", "in")),
            PatchCable(from: PortReference("keys", "gate"), to: PortReference("amp", "cv")),
            PatchCable(from: PortReference("amp", "out"), to: PortReference("out", "in")),
          ]))
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
        return (0..<frames).reduce(0) { max($0, abs(left[$1])) }
      }
      #expect(loudness() == 0)
      model.noteDown(48)
      #expect(model.sounding == [48])
      #expect(model.lastNote == 48)
      #expect(loudness() > 0.01)
      model.turn("out", "level", to: 0)
      model.endTurn()
      _ = loudness()
      #expect(loudness() == 0)
      model.turn("out", "level", to: 0.7)
      model.endTurn()
      model.noteUp(48)
      _ = loudness()
      #expect(loudness() == 0)
      #expect(model.sounding.isEmpty)
    }
  }

  /// The keyboard's rule, as the reference's tests have it: the newest N held keys sound.
  struct RackKeyboardTests {
    typealias State = RackKeyboard.VoiceState

    @Test func oneVoiceIsLastNotePriorityWithLegato() {
      var keys = RackKeyboard(voices: 1)
      #expect(keys.down(48, velocity: 1) == [State(voice: 0, note: 48, gate: 1, velocity: 1)])
      #expect(keys.down(52, velocity: 0.5) == [State(voice: 0, note: 52, gate: 1, velocity: 0.5)])
      // Letting the newer go returns to the one still held, without the gate falling.
      #expect(keys.up(52) == [State(voice: 0, note: 48, gate: 1, velocity: 1)])
      #expect(keys.up(48) == [State(voice: 0, note: 48, gate: 0, velocity: 0)])
      #expect(keys.up(48).isEmpty)
    }

    @Test func aRepeatedKeyRetriggers() {
      var keys = RackKeyboard(voices: 2)
      _ = keys.down(48, velocity: 1)
      #expect(keys.down(48, velocity: 0.3) == [State(voice: 0, note: 48, gate: 1, velocity: 0.3)])
    }

    @Test func aChordSpreadsAndTheOldestIsStolenAndReturned() {
      var keys = RackKeyboard(voices: 2)
      _ = keys.down(48, velocity: 1)
      _ = keys.down(52, velocity: 1)
      #expect(keys.playing == [48, 52])
      // A third note takes the oldest's voice; letting it go gives it back.
      #expect(keys.down(55, velocity: 1) == [State(voice: 0, note: 55, gate: 1, velocity: 1)])
      #expect(keys.up(55) == [State(voice: 0, note: 48, gate: 1, velocity: 1)])
    }

    @Test func aReleasedVoiceRingsWhileAnotherIsFree() {
      var keys = RackKeyboard(voices: 2)
      _ = keys.down(48, velocity: 1)
      _ = keys.up(48)
      // Voice 0 has just been let go, so the next note takes voice 1, the one idle longest.
      #expect(keys.down(50, velocity: 1) == [State(voice: 1, note: 50, gate: 1, velocity: 1)])
    }

    @Test func theKeysAreTheReferences() {
      #expect(RackKeyboard.keyMap["z"] == 0)
      #expect(RackKeyboard.keyMap["s"] == 1)
      #expect(RackKeyboard.keyMap["m"] == 11)
      #expect(RackKeyboard.keyMap["q"] == 12)
      #expect(RackKeyboard.keyMap["7"] == 22)
      #expect(RackKeyboard.keyMap["u"] == 23)
      #expect(RackKeyboard.name(36) == "C2")
      #expect(RackKeyboard.name(61) == "C#4")
      #expect(RackKeyboard.name(-1) == "B-2")
    }

    @Test func aValueIsWrittenAsTheReferenceWritesIt() {
      func param(_ min: Double, _ max: Double) -> ParamDef {
        ParamDef("x", "X", min: min, max: max, default: min)
      }
      #expect(ParamControl.display(param(20, 18000), 440) == "440")
      #expect(ParamControl.display(param(20, 18000), 1200) == "1.20k")
      #expect(ParamControl.display(param(0.001, 5), 0.05) == "50ms")
      #expect(ParamControl.display(param(0.001, 5), 0.5) == "0.50s")
      #expect(ParamControl.display(param(-24, 24), 7) == "+7")
      #expect(ParamControl.display(param(-24, 24), -3) == "-3")
      #expect(ParamControl.display(param(0, 1), 0.25) == "0.25")
    }
  }
#endif
