import ConformanceSupport
import DriftboxDocument
import DriftboxRack
import Foundation
import Testing

/// Every rack fixture: the plan the reference compiles each patch to, field for field, and the
/// render its headless `RackRenderer` makes of it, block by block, with the same knob moves at the
/// same blocks.
struct RackConformanceTests {
  struct Case {
    let name: String
    let patch: Patch
    let blocks: Int
    let events: [JSONValue]
    let plan: JSONObject
  }

  struct Missing: Error {}

  static func need<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
  }

  static func cases() throws -> [Case] {
    let all = try need(JSONValue(parsing: try Fixtures.text("rack/cases.json"))?.array)
    return try all.map { value in
      let object = try need(value.object)
      let patchJSON = try need(object["patch"]?.object)
      let modules = try (patchJSON["modules"]?.array ?? []).map { value -> PatchModule in
        let module = try need(value.object)
        var params: [String: Double] = [:]
        for (key, param) in module["params"]?.object?.members ?? [] { params[key] = param.finite }
        return PatchModule(
          id: try need(module["id"]?.string), type: try need(module["type"]?.string), params: params,
          bypassed: module["bypassed"]?.bool ?? false)
      }
      let cables = try (patchJSON["cables"]?.array ?? []).map { value -> PatchCable in
        let cable = try need(value.object)
        let from = try need(cable["from"]?.array?.compactMap(\.string))
        let to = try need(cable["to"]?.array?.compactMap(\.string))
        return PatchCable(from: PortReference(from[0], from[1]), to: PortReference(to[0], to[1]))
      }
      return Case(
        name: try need(object["name"]?.string),
        patch: Patch(modules: modules, cables: cables, voices: patchJSON["voices"]?.finite),
        blocks: Int(try need(object["blocks"]?.finite)), events: object["events"]?.array ?? [],
        plan: try need(object["plan"]?.object))
    }
  }

  static let names = (try? cases().map(\.name)) ?? []

  /// The cases load at all: a parameterised test over none of them would pass, and say nothing.
  @Test func everyCaseLoads() throws {
    let cases = try Self.cases()
    #expect(cases.count == 18)
    #expect(Self.names.count == cases.count)
  }

  @Test(arguments: names)
  func compilesAsTheReferenceDoes(name: String) throws {
    let fixture = try #require(try Self.cases().first { $0.name == name })
    let plan = compile(fixture.patch)
    let expected = fixture.plan
    #expect(plan.buffers == Int(expected["buffers"]?.finite ?? -1))
    #expect(plan.voices == Int(expected["voices"]?.finite ?? -1))
    #expect(plan.voiceWidths == (expected["voiceWidths"]?.array ?? []).compactMap { $0.finite.map(Int.init) })
    let ints = { (value: JSONValue?) in (value?.array ?? []).compactMap { $0.finite.map(Int.init) } }
    let nodes = expected["nodes"]?.array ?? []
    #expect(plan.nodes.count == nodes.count)
    for (mine, theirs) in zip(plan.nodes, nodes.compactMap(\.object)) {
      #expect(mine.id == theirs["id"]?.string)
      #expect(mine.inlets == ints(theirs["inlets"]), "\(mine.id) inlets")
      #expect(mine.outlets == ints(theirs["outlets"]), "\(mine.id) outlets")
      #expect(mine.params == ints(theirs["params"]), "\(mine.id) params")
      #expect(mine.voices == Int(theirs["voices"]?.finite ?? -1))
      #expect(mine.inletConnected == (theirs["inletConnected"]?.array ?? []).compactMap(\.bool))
      #expect(mine.outletConnected == (theirs["outletConnected"]?.array ?? []).compactMap(\.bool))
      #expect(mine.inletTrims == (theirs["inletTrims"]?.array ?? []).map { $0.finite.map(Int.init) })
    }
    let outputs = (expected["outputs"]?.array ?? []).compactMap(\.object)
    #expect(plan.outputs.count == outputs.count)
    for (mine, theirs) in zip(plan.outputs, outputs) {
      #expect(mine.buffer == Int(theirs["buffer"]?.finite ?? -1))
      #expect(mine.right == theirs["right"]?.finite.map(Int.init))
      #expect(mine.pan == theirs["pan"]?.finite.map(Int.init))
    }
    let params = (expected["params"]?.array ?? []).compactMap(\.object)
    #expect(plan.params.map(\.value) == params.compactMap { $0["value"]?.finite })
    #expect(plan.params.map(\.stepped) == params.compactMap { $0["stepped"]?.bool })
    let notes = (expected["notes"]?.array ?? []).compactMap(\.object)
    #expect(plan.notes.map(\.kind) == notes.compactMap { $0["kind"]?.string })
    #expect(plan.notes.map(\.module) == notes.map { $0["module"]?.string })
  }

  @Test(arguments: names)
  func rendersAsTheReferenceDoes(name: String) throws {
    let fixture = try #require(try Self.cases().first { $0.name == name })
    let data = try Fixtures.data("rack/\(name).f32")
    let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let frames = fixture.blocks * 128
    #expect(expected.count == frames * 2)

    let renderer = RackRenderer(sampleRate: 48000, frames: 128)
    renderer.patch = fixture.patch
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for block in 0..<fixture.blocks {
      for event in fixture.events.compactMap(\.array) where Int(event[0].finite ?? -1) == block {
        let kind = event[1].string ?? ""
        let module = event[2].string ?? ""
        let param = event[3].string ?? ""
        let value = event[4].finite ?? 0
        let extra = event.count > 5 ? event[5].finite.map(Int.init) : nil
        switch kind {
        case "param": renderer.setParam(module, param, value)
        case "voice": renderer.setParam(module, param, value, voice: extra)
        default: renderer.scheduleParam(module, param, value, frame: extra ?? 0)
        }
      }
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          renderer.process(left: l.baseAddress! + block * 128, right: r.baseAddress! + block * 128)
        }
      }
    }
    var worst: Float = 0
    var firstDifference = -1
    var loudest: Float = 0
    for index in 0..<frames {
      let difference = max(abs(left[index] - expected[index]), abs(right[index] - expected[frames + index]))
      if difference > 0, firstDifference < 0 { firstDifference = index }
      worst = max(worst, difference)
      loudest = max(loudest, abs(expected[index]))
    }
    #expect(loudest > 0.01, "\(name) renders something")
    // The same arithmetic in the same order: bit-identical on the Mac, and the tolerance is for
    // another platform's libm differing in the last bit of a transcendental.
    #expect(worst < 1e-5, "\(name) differs by \(worst), first at frame \(firstDifference)")
  }
}
