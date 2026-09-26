import DriftboxRack

/// A module's guide, as the reference's `ModuleGuide` assembles it: what it does, where its signal
/// goes, how it works and what to try first where a guide was written for it, every control a hand
/// can set and its range, and what to watch for. Words only, laid out by whichever platform shows
/// it.
public struct RackGuide: Equatable, Sendable {
  public enum Section: Equatable, Sendable {
    /// A paragraph.
    case prose(String)
    /// The inlets on one side and the outlets on the other, each said as a sentence where there
    /// are none.
    case flow(ins: [String], outs: [String], noIns: String, noOuts: String)
    /// Terms and what each means.
    case definitions([Term])
    /// Steps, in order.
    case steps([String])
    /// Points, in no order.
    case notes([String])
  }

  /// A heading and what is under it.
  public struct Part: Equatable, Sendable {
    public var heading: String
    public var body: Section
  }

  public struct Term: Equatable, Sendable {
    public var term: String
    public var meaning: String
  }

  /// What it is on: "Driftbox / Filters / Module guide".
  public var trail: String
  public var title: String
  public var parts: [Part]

  /// `type`'s guide, from its definition and the face its card has; nil for a type there is none of.
  public static func guide(for type: String) -> RackGuide? {
    guard let def = RackModules.registry[type] else { return nil }
    return guide(def, face: ModuleFace.all.first { $0.type == type })
  }

  public static func guide(_ def: ModuleDef, face: ModuleFace?) -> RackGuide {
    let written = face?.guide
    var parts = [
      Part(
        heading: "What it does",
        body: .prose(written?.overview ?? face?.blurb ?? "\(def.name) is a rack module.")),
      Part(
        heading: "Signal flow",
        body: .flow(
          ins: def.inlets.map(port), outs: def.outlets.map(port),
          noIns: "None — this device creates or controls signals.",
          noOuts: "None — this device ends or manages the signal.")),
    ]
    if let written {
      parts.append(
        Part(
          heading: "How it works",
          body: .definitions(written.concepts.map { Term(term: $0.title, meaning: $0.body) })))
      parts.append(Part(heading: "Try this first", body: .steps(written.firstPatch)))
    }
    let controls = def.params.filter { !$0.hidden }
    parts.append(
      Part(
        heading: "Controls",
        body: controls.isEmpty
          ? .prose("No front-panel controls.")
          : .definitions(
            controls.map { Term(term: $0.name, meaning: range($0, labels: face?.labels[$0.id])) })))
    if let watch = written?.watchFor, !watch.isEmpty {
      parts.append(Part(heading: "Watch for", body: .notes(watch)))
    }
    return RackGuide(
      trail: "Driftbox / \(face?.group ?? "Device") / Module guide", title: def.name, parts: parts)
  }

  static func port(_ port: Port) -> String { port.stereo ? "\(port.name) · stereo" : port.name }

  /// A control's range as the reference says it: its selector's words, or from where to where and
  /// where it starts.
  static func range(_ param: ParamDef, labels: [String]?) -> String {
    if let labels, !labels.isEmpty { return labels.joined(separator: " · ") }
    return "\(number(param.min))–\(number(param.max)) · starts at \(number(param.defaultValue))"
  }

  /// A number as JavaScript writes one into a string: whole numbers without a point.
  static func number(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e21 { return String(Int64(value)) }
    return "\(value)"
  }
}
