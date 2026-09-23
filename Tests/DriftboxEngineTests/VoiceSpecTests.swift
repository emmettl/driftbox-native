import ConformanceSupport
import DriftboxDocument
import DriftboxEngine
import DriftboxSeq
import Foundation
import Testing

struct VoiceSpecTests {
  /// Every voice, across a grid of panels and both velocities, describes exactly the sound the
  /// reference's builder describes. With this pinned, a difference in the sound is the renderer's.
  @Test func everyVoiceDescribesWhatTheReferenceDescribes() throws {
    let cases = try #require(JSONValue(parsing: try Fixtures.text("voices/specs.json"))?.array)
    #expect(cases.count == 22 * 9 * 2)

    var found: [String] = []
    for fixture in cases.compactMap(\.object) {
      let id = try #require(fixture["voice"]?.string)
      let voice = try #require(voice(id: id), "no voice \(id)")
      let accent = try #require(fixture["accent"]?.finite)
      var params = VoiceParams()
      for (knob, name) in VoiceParams.names.enumerated() {
        params[knob] = try #require(fixture["params"]?.object?[name]?.finite)
      }
      let expected = try #require(fixture["spec"])
      collectDifferences(
        between: json(voice.build(params, accent: accent)), and: expected, at: "\(id)@\(accent)",
        ignoringKeyOrder: true, into: &found)
    }
    #expect(found.isEmpty, "\(found.count) differences, first: \(found.prefix(5))")
  }

  /// The metronome's two clicks, exactly as the reference describes them.
  @Test func theClicksAreTheReferencesClicks() throws {
    let cases = try #require(JSONValue(parsing: try Fixtures.text("voices/metronome.json"))?.array)
    #expect(cases.count == 2)
    var found: [String] = []
    for fixture in cases.compactMap(\.object) {
      let strong = try #require(fixture["strong"]?.bool as Bool?)
      let expected = try #require(fixture["spec"])
      collectDifferences(
        between: json(metronomeClick(strong: strong)), and: expected, at: strong ? "strong" : "weak",
        ignoringKeyOrder: true, into: &found)
    }
    #expect(found.isEmpty, "\(found)")
  }

  @Test func theKitIsTheReferencesKit() throws {
    let kit = try #require(JSONValue(parsing: try Fixtures.text("voices/kit.json"))?.array)
    #expect(kit.count == allVoices.count)
    for (entry, voice) in zip(kit.compactMap(\.object), allVoices) {
      #expect(entry["id"]?.string == voice.id)
      #expect(entry["name"]?.string == voice.name)
      #expect(entry["machine"]?.string == (voice.machine == .tr808 ? "tr808" : "tr909"))
      #expect(entry["choke"]?.string == voice.choke)
      #expect(entry["trim"]?.finite == voice.trim)
      #expect(entry["pitched"]?.object?["low"]?.finite == voice.pitched?.lowerBound)
      #expect(entry["pitched"]?.object?["high"]?.finite == voice.pitched?.upperBound)
    }
  }
}

// A spec in the reference's shape.

private func json(_ spec: VoiceSpec) -> JSONValue {
  var out = JSONObject()
  out["duration"] = .number(spec.duration)
  out["gain"] = .number(spec.gain)
  if let drive = spec.drive { out["drive"] = .number(drive) }
  out["sources"] = .array(spec.sources.map(json))
  if let filter = spec.filter { out["filter"] = json(filter) }
  if let pan = spec.pan { out["pan"] = .number(pan) }
  if let trim = spec.trim { out["trim"] = .number(trim) }
  return .object(out)
}

private func json(_ source: Source) -> JSONValue {
  var out = JSONObject()
  switch source.generator {
  case .oscillator(let oscillator):
    out["kind"] = .string("osc")
    let type =
      switch oscillator.type {
      case .sine: "sine"
      case .triangle: "triangle"
      case .square: "square"
      case .sawtooth: "sawtooth"
      }
    out["type"] = .string(type)
    out["frequency"] = .number(oscillator.frequency)
    if let pitch = oscillator.pitch { out["pitch"] = .array(pitch.map(json)) }
  case .noise(let noise):
    out["kind"] = .string("noise")
    if let value = noise.sampleRate { out["sampleRate"] = .number(value) }
    if let value = noise.bitDepth { out["bitDepth"] = .number(value) }
    if let value = noise.seed { out["seed"] = .number(value) }
    if let value = noise.playbackRate { out["playbackRate"] = .number(value) }
  }
  out["gain"] = .number(source.gain)
  out["amp"] = .array(source.amp.map(json))
  if let filter = source.filter { out["filter"] = json(filter) }
  if let delay = source.delay { out["delay"] = .number(delay) }
  return .object(out)
}

private func json(_ filter: FilterSpec) -> JSONValue {
  var out = JSONObject()
  let type =
    switch filter.type {
    case .lowpass: "lowpass"
    case .highpass: "highpass"
    case .bandpass: "bandpass"
    }
  out["type"] = .string(type)
  out["frequency"] = .number(filter.frequency)
  if let q = filter.q { out["Q"] = .number(q) }
  if let envelope = filter.envelope { out["envelope"] = .array(envelope.map(json)) }
  return .object(out)
}

private func json(_ point: Breakpoint) -> JSONValue {
  var out = JSONObject()
  out["to"] = .number(point.to)
  out["at"] = .number(point.at)
  if let curve = point.curve { out["curve"] = .string(curve == .linear ? "lin" : "exp") }
  return .object(out)
}
