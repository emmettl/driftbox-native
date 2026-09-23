#if canImport(AVFoundation)
  import DriftboxRack
  import Foundation
  import Testing

  @testable import DriftboxApp

  /// The Combinator finished: its routings drive their knobs as it turns, the routing is edited
  /// as the reference's panel edits it, and a controller on the desk can be taught a rotary.
  @MainActor
  struct RackRoutingTests {
    /// A Combinator, a VCO through a ladder into an Out, and a keyboard.
    static func patch(_ routes: [ModRoute] = []) -> Patch {
      Patch(
        modules: [
          PatchModule(id: "combi", type: "combi"), PatchModule(id: "keys", type: "midi"),
          PatchModule(id: "osc", type: "vco"), PatchModule(id: "filter", type: "ladder"),
          PatchModule(id: "out", type: "out"),
        ],
        cables: [
          PatchCable(from: PortReference("keys", "pitch"), to: PortReference("osc", "pitch")),
          PatchCable(from: PortReference("osc", "out"), to: PortReference("filter", "in")),
          PatchCable(from: PortReference("filter", "out"), to: PortReference("out", "in")),
        ],
        modulation: routes)
    }

    static func model(_ routes: [ModRoute] = [], memory: UserDefaults? = nil) -> RackModel {
      let model = RackModel(memory: memory)
      model.open(patch(routes), name: "Test")
      return model
    }

    static let level = ModRoute(from: PortReference("combi", "rotary1"), to: PortReference("out", "level"))

    // MARK: Routing, live

    @Test func aRotaryMovesWhatItDrivesAsItTurns() {
      let model = Self.model([
        ModRoute(
          from: PortReference("combi", "rotary1"), to: PortReference("filter", "cutoff"), min: 200, max: 8200)
      ])
      // Opened settled: the rotary rests at 64, so the cutoff is where that puts it.
      #expect(model.patch.modules[3].params["cutoff"] == 200 + 8000 * (64.0 / 127))
      model.turn("combi", "rotary1", to: 127)
      #expect(model.patch.modules[3].params["cutoff"] == 8200)
      model.turn("combi", "rotary1", to: 0)
      model.endTurn()
      #expect(model.patch.modules[3].params["cutoff"] == 200)
      // One turn of the rotary is one step back, the knobs it drove included.
      model.undo()
      #expect(model.patch.modules[0].params["rotary1"] == nil)
      #expect(model.patch.modules[3].params["cutoff"] == 200 + 8000 * (64.0 / 127))
    }

    @Test func aKnobARoutingDrivesIsTakenBackAndIsNoEdit() {
      let model = Self.model([Self.level])
      let before = model.patch
      model.turn("out", "level", to: 0.1)
      model.endTurn()
      #expect(model.patch == before)
      #expect(!model.canUndo)
      #expect(model.isRouted("out", "level"))
      #expect(!model.isRouted("out", "pan"))
    }

    /// Heard, not only written down: the rotary turning the Out down silences it.
    @Test func whatARotaryDrivesIsHeard() {
      let model = Self.model([Self.level])
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
      model.noteDown(48)
      #expect(loudness() > 0.01)
      model.turn("combi", "rotary1", to: 0)
      model.endTurn()
      _ = loudness()
      #expect(loudness() == 0)
      model.turn("combi", "rotary1", to: 127)
      model.endTurn()
      #expect(loudness() > 0.01)
    }

    // MARK: Editing the routing

    @Test func aNewRoutingFindsACutoffAndAFreeControl() throws {
      let model = Self.model()
      model.addRoute("combi")
      #expect(
        model.patch.modulation == [
          ModRoute(from: PortReference("combi", "rotary1"), to: PortReference("filter", "cutoff"))
        ])
      // Swept end to end: the rotary at rest puts the cutoff just past the middle of its range.
      let cutoff = try #require(RackModel.routable("ladder").first { $0.id == "cutoff" })
      #expect(
        model.patch.modules[3].params["cutoff"] == cutoff.min + (cutoff.max - cutoff.min) * (64.0 / 127))
      model.addRoute("combi")
      #expect(model.patch.modulation.map(\.from.port) == ["rotary1", "rotary2"])
      #expect(model.undoTitle == "Undo Add Routing")
      model.undo()
      #expect(model.patch.modulation.count == 1)
    }

    @Test func withNothingToDriveThereIsNoNewRouting() {
      let model = RackModel()
      model.open(Patch(modules: [PatchModule(id: "combi", type: "combi")], cables: []), name: "Alone")
      #expect(model.defaultTarget("combi") == nil)
      model.addRoute("combi")
      #expect(model.patch.modulation.isEmpty)
      #expect(!model.canUndo)
    }

    @Test func aRoutingAimedElsewhereLosesTheOldKnobsRange() {
      let model = Self.model([
        ModRoute(
          from: PortReference("combi", "rotary1"), to: PortReference("filter", "cutoff"), min: 200, max: 800)
      ])
      model.setRoute(0) { $0.to = PortReference("filter", "resonance") }
      #expect(
        model.patch.modulation[0]
          == ModRoute(
            from: PortReference("combi", "rotary1"), to: PortReference("filter", "resonance")))
      // Another module: its first knob, since the old one's id means nothing there.
      model.setRoute(0) { $0.to = PortReference("osc", $0.to.port) }
      let first = RackModel.routable("vco")[0].id
      #expect(model.patch.modulation[0].to == PortReference("osc", first))
      // An end can be set, and cleared back to the knob's own limit.
      model.setRoute(0) { $0.max = 2 }
      #expect(model.patch.modulation[0].max == 2)
      model.setRoute(0) { $0.max = nil }
      #expect(model.patch.modulation[0].max == nil)
      model.setRoute(0) { $0.min = .nan }
      #expect(model.patch.modulation[0].min == nil)
      // A source changes on its own.
      model.setRoute(0) { $0.from = PortReference("combi", "button2") }
      #expect(model.patch.modulation[0].from.port == "button2")
    }

    @Test func removingTheLastRoutingLeavesNone() {
      let model = Self.model([Self.level])
      model.removeRoute(0)
      #expect(model.patch.modulation.isEmpty)
      model.removeRoute(3)
      #expect(model.undoTitle == "Undo Remove Routing")
    }

    @Test func theRoutingClosesWithItsCombinator() {
      let model = Self.model()
      model.editRoutes("combi")
      #expect(model.editingRoutes == "combi")
      model.remove("combi")
      #expect(model.editingRoutes == nil)
    }

    @Test func theInspectorRoundsAsTheReferenceDoes() {
      #expect(RouteRow.round(1234.56) == "1235")
      #expect(RouteRow.round(0.7234) == "0.72")
      #expect(RouteRow.round(3) == "3")
      #expect(RouteRow.round(-0.655) == "-0.65")
    }

    // MARK: Learning a controller

    @Test func aControllerTurnedWhileArmedIsLearnt() throws {
      let suite = "rack-routing-tests-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }
      let model = Self.model([Self.level], memory: memory)
      model.startCcLearn("combi", "rotary1")
      model.midi([0xB2, 74, 10])
      #expect(model.ccLearning == nil)
      #expect(model.ccBindings == [RackCC.Binding(cc: 74, module: "combi", param: "rotary1")])
      // Learning did not move the rotary; the next turn of the controller does, on any channel,
      // and the routing follows.
      #expect(model.patch.modules[0].params["rotary1"] == nil)
      model.midi([0xB5, 74, 0])
      #expect(model.patch.modules[0].params["rotary1"] == 0)
      #expect(model.patch.modules[4].params["level"] == 0)
      // Remembered, beside the patch rather than in it.
      #expect(RackModel(memory: memory).ccBindings == model.ccBindings)
      model.clearCcBinding("combi", "rotary1")
      #expect(model.ccBindings.isEmpty)
      #expect(RackCC.load(memory).isEmpty)
    }

    @Test func learningWinsOverWhatAControllerAlreadyDrives() {
      let model = Self.model()
      model.startCcLearn("combi", "rotary1")
      model.midi([0xB0, 20, 100])
      model.startCcLearn("combi", "rotary2")
      model.midi([0xB0, 20, 100])
      // Taught twice, moved by neither lesson; now it drives both.
      #expect(model.patch.modules[0].params["rotary1"] == nil)
      #expect(model.ccBindings.map(\.param) == ["rotary1", "rotary2"])
      model.midi([0xB0, 20, 127])
      #expect(model.patch.modules[0].params["rotary1"] == 127)
      #expect(model.patch.modules[0].params["rotary2"] == 127)
      model.startCcLearn("combi", "rotary3")
      model.cancelCcLearn()
      #expect(model.ccLearning == nil)
    }

    @Test func aBindingForAModuleThatIsNotHereWaits() {
      let model = Self.model()
      model.startCcLearn("gone", "rotary1")
      model.midi([0xB0, 21, 0])
      model.midi([0xB0, 21, 90])
      #expect(model.ccBindings.count == 1)
      #expect(!model.canUndo)
    }
  }

  /// The reference's `cc.test.ts`, one for one.
  struct RackCCTests {
    typealias Binding = RackCC.Binding
    static func binding(cc: Int = 74, channel: Int = 0, module: String = "combi-1", param: String = "rotary1")
      -> Binding
    {
      Binding(cc: cc, channel: channel, module: module, param: param)
    }

    @Test func learningReplacesWhatATargetHad() {
      let second = RackCC.learn(RackCC.learn([], Self.binding(cc: 20)), Self.binding(cc: 21))
      #expect(second.map(\.cc) == [21])
    }

    @Test func oneControllerCanDriveSeveralTargets() {
      let bindings = RackCC.learn(RackCC.learn([], Self.binding()), Self.binding(param: "rotary2"))
      #expect(bindings.count == 2)
      #expect(RackCC.targets(bindings, cc: 74, channel: 1).count == 2)
      #expect(RackCC.learn(RackCC.learn([], Self.binding()), Self.binding(module: "combi-2")).count == 2)
    }

    @Test func forgettingDropsJustThatTarget() {
      let bindings = RackCC.learn(RackCC.learn([], Self.binding()), Self.binding(param: "rotary2"))
      #expect(RackCC.forget(bindings, module: "combi-1", param: "rotary1").count == 1)
      let one = RackCC.learn([], Self.binding())
      #expect(RackCC.forget(one, module: "combi-1", param: "rotary4") == one)
    }

    @Test func channelZeroHearsEveryChannel() {
      let any = RackCC.learn([], Self.binding())
      for channel in [1, 7, 16] { #expect(RackCC.targets(any, cc: 74, channel: channel).count == 1) }
      let three = RackCC.learn([], Self.binding(channel: 3))
      #expect(RackCC.targets(three, cc: 74, channel: 3).count == 1)
      #expect(RackCC.targets(three, cc: 74, channel: 4).isEmpty)
      #expect(RackCC.targets(any, cc: 75, channel: 1).isEmpty)
    }

    @Test func aControllerValueIsInTheParamsOwnUnits() throws {
      let rotary = try #require(RackModules.registry["combi"]?.params.first { $0.id == "rotary1" })
      let cutoff = try #require(RackModules.registry["ladder"]?.params.first { $0.id == "cutoff" })
      let shape = try #require(RackModules.registry["vco"]?.params.first { $0.id == "shape" })
      #expect([0, 64, 127].map { RackCC.value($0, rotary) } == [0, 64, 127])
      #expect(RackCC.value(0, cutoff) == cutoff.min)
      #expect(RackCC.value(127, cutoff) == cutoff.max)
      for raw in [0, 40, 90, 127] {
        let value = RackCC.value(raw, shape)
        #expect(value == value.rounded())
      }
      #expect(RackCC.value(0, shape) == shape.min)
      #expect(RackCC.value(127, shape) == shape.max)
      #expect(RackCC.value(-5, cutoff) == cutoff.min)
      #expect(RackCC.value(999, cutoff) == cutoff.max)
    }

    @Test func storageRoundTripsAndForgivesWhatItCannotRead() throws {
      let suite = "rack-cc-tests-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }
      let bindings = [Self.binding(), Self.binding(cc: 20, channel: 3, param: "button1")]
      RackCC.save(bindings, to: memory)
      #expect(RackCC.load(memory) == bindings)
      #expect(RackCC.load(nil).isEmpty)
      RackCC.save(bindings, to: nil)
      for text in ["", "not json", "{}", "[1,2,3]", "null"] {
        memory.set(text, forKey: RackCC.key)
        #expect(RackCC.load(memory).isEmpty)
      }
      // One bad entry costs only itself; a controller or channel MIDI cannot send is refused.
      memory.set(
        #"[{"cc":74,"channel":0,"module":"combi-1","param":"rotary1"},{"cc":999},{"cc":5},"#
          + #"{"cc":128,"channel":0,"module":"a","param":"b"},{"cc":1,"channel":17,"module":"a","param":"b"},"#
          + #"{"cc":20,"channel":0,"module":"combi-1","param":"rotary2"}]"#,
        forKey: RackCC.key)
      #expect(RackCC.load(memory).map(\.cc) == [74, 20])
    }

    @Test func aModulesBindingsAreKeyedByParamAndSaidShortly() {
      let bindings = RackCC.learn(RackCC.learn([], Self.binding()), Self.binding(cc: 20, param: "button1"))
      let mine = RackCC.bindings(bindings, for: "combi-1")
      #expect(mine["rotary1"]?.cc == 74)
      #expect(mine["button1"]?.cc == 20)
      #expect(RackCC.bindings(bindings, for: "combi-2").isEmpty)
      #expect(RackCC.describe(Self.binding()) == "CC 74")
      #expect(RackCC.describe(Self.binding(channel: 3)) == "CC 74 ch3")
    }
  }
#endif
