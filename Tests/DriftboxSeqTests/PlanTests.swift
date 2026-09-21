import ConformanceSupport
import DriftboxDocument
import DriftboxSeq
import Foundation
import Testing

private let generated = Fixtures.root.deletingLastPathComponent().appendingPathComponent("generated/events")

struct PlanTests {
  /// Every hit, its time, and the knobs and sends resolved at that position, for the opening bars
  /// of every catalogue song — equal to the reference's `planSong`, number for number, in order.
  @Test(arguments: try Fixtures.songIds())
  func plansWhatTheReferencePlans(id: String) throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/\(id).song.json")))
    let fixture = try #require(JSONValue(parsing: try Fixtures.text("events/\(id).plan.json"))?.object)
    let bars = try #require(fixture["bars"]?.finite)
    let expected = try #require(fixture["steps"]?.array)

    #expect(fixture["songBars"]?.finite == Double(song.bars))

    let planned = song.plan(bars: Int(bars)).map(json)
    #expect(planned.count == expected.count)

    var differences: [String] = []
    for (index, pair) in zip(planned, expected).enumerated() {
      collectDifferences(between: pair.0, and: pair.1, at: "steps[\(index)]", into: &differences)
    }
    #expect(differences.isEmpty, "\(differences.count) differences, first: \(differences.prefix(5))")
  }

  /// The catalogue uses no machine clips, short drum lanes, flams or filter strikes, so these
  /// songs exist to be awkward: all of those at once, bars of three different lengths, tempo and
  /// swing under automation, a voice no machine owns, and clips launched over the top.
  @Test func plansTheAwkwardSongs() throws {
    let cases = try #require(JSONValue(parsing: try Fixtures.text("events/synthetic.json"))?.array)
    #expect(cases.count == 3)
    for fixture in cases.compactMap(\.object) {
      let name = fixture["name"]?.string ?? "?"
      let text = try #require(fixture["song"]?.string)
      let song = try #require(SongCodec.decode(text))
      var selection = ClipSelection()
      for slot in ClipSlot.allCases { selection[slot] = fixture["selection"]?.object?[slot.name]?.string }

      let expected = try #require(fixture["steps"]?.array)
      let bars = try #require(fixture["bars"]?.finite)
      let planned = song.plan(bars: Int(bars), selection: selection).map(json)
      #expect(planned.count == expected.count, "\(name)")

      var differences: [String] = []
      for (index, pair) in zip(planned, expected).enumerated() {
        collectDifferences(between: pair.0, and: pair.1, at: "steps[\(index)]", into: &differences)
      }
      #expect(
        differences.isEmpty, "\(name): \(differences.count) differences, first: \(differences.prefix(5))")
    }
  }

  /// Whole songs, start to finish, when `emit.mjs --full` has been run. Too large to check in.
  @Test(
    .enabled(if: FileManager.default.fileExists(atPath: generated.path)), arguments: try Fixtures.songIds())
  func plansWholeSongs(id: String) throws {
    let song = try #require(SongCodec.decode(try Fixtures.text("documents/\(id).song.json")))
    let text = String(
      decoding: try Data(contentsOf: generated.appendingPathComponent("\(id).plan.json")), as: UTF8.self)
    let expected = try #require(JSONValue(parsing: text)?.object?["steps"]?.array)
    let planned = song.plan(bars: song.bars).map(json)
    #expect(planned.count == expected.count)

    var differences: [String] = []
    for (index, pair) in zip(planned, expected).enumerated() {
      collectDifferences(between: pair.0, and: pair.1, at: "steps[\(index)]", into: &differences)
    }
    #expect(differences.isEmpty, "\(differences.count) differences, first: \(differences.prefix(5))")
  }

  @Test func theWholeSongPlansAreThereWhenTheyMustBe() {
    let required = ProcessInfo.processInfo.environment["DRIFTBOX_REQUIRE_GENERATED"] != nil
    #expect(
      FileManager.default.fileExists(atPath: generated.path) || !required,
      "DRIFTBOX_REQUIRE_GENERATED is set and emit.mjs --full has not run")
  }

  @Test func theCatalogueIsAllThere() throws {
    #expect(try Fixtures.songIds().count == 25)
  }
}

// A plan in the reference's shape and key order.

private func json(_ plan: StepPlan) -> JSONValue {
  var out = JSONObject()
  out["time"] = .number(plan.time)
  out["stepSeconds"] = .number(plan.stepSeconds)
  out["bpm"] = .number(plan.bpm)
  out["fx"] = json(plan.fx)
  out["pcf"] = .number(Double(plan.pcf.rawValue))
  out["drums"] = .array(
    plan.drums.map { hit in
      var out = JSONObject()
      out["voiceId"] = .string(hit.voiceId)
      out["time"] = .number(hit.time)
      out["accent"] = .number(hit.accent)
      out["params"] = json(hit.params)
      out["sends"] = json(hit.sends)
      return .object(out)
    })
  out["bass"] = .array(
    plan.bass.map { hit in
      var out = JSONObject()
      out["voiceId"] = .string(hit.voiceId)
      out["time"] = .number(hit.time)
      out["note"] = json(hit.note)
      out["sends"] = json(hit.sends)
      return .object(out)
    })
  return .object(out)
}

private func json(_ note: BassNote) -> JSONValue {
  var out = JSONObject()
  out["frequency"] = .number(note.frequency)
  out["glide"] = .number(note.glide)
  if let from = note.glideFrom { out["glideFrom"] = .number(from) }
  out["retrigger"] = .bool(note.retrigger)
  out["gate"] = .number(note.gate)
  out["wave"] = .string(note.wave == .sawtooth ? "sawtooth" : "square")
  out["gain"] = .number(note.gain)
  out["resonance"] = .number(note.resonance)
  var filter = JSONObject()
  filter["peak"] = .number(note.filterPeak)
  filter["base"] = .number(note.filterBase)
  filter["decay"] = .number(note.filterDecay)
  out["filter"] = .object(filter)
  return .object(out)
}

private func json<Knobs: KnobSet>(_ knobs: Knobs) -> JSONValue {
  var out = JSONObject()
  for knob in 0..<Knobs.names.count { out[Knobs.names[knob]] = .number(knobs[knob]) }
  return .object(out)
}
