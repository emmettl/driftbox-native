import DriftboxRack

/// What the rack says about a document it did not author: the reference's `documentNotice`,
/// with "Sequencer →" become the groovebox window, since here the rack does not leave for the
/// song but opens it beside itself. Nothing for a patch built here.
public struct DocumentNotice: Equatable, Sendable {
  public var label: String
  public var retained: String
  public var guidance: String

  public init(label: String, retained: String, guidance: String) {
    self.label = label
    self.retained = retained
    self.guidance = guidance
  }

  /// `song` is the patterns and tempo of the song carried, or nil when this build cannot read it.
  public static func notice(_ compatibility: PatchCompatibility, song: (patterns: Int, bpm: Double)?)
    -> DocumentNotice?
  {
    let label: String
    switch compatibility {
    case .rackNative: return nil
    case .grooveboxCompatible: label = "groovebox compatible"
    case .rackExtended: label = "rack extended"
    }
    guard let song else {
      return DocumentNotice(
        label: label,
        retained: "A song from a newer groovebox build is retained exactly but cannot be edited here.",
        guidance: "This build keeps it as it is, but cannot play or edit it.")
    }
    let bpm = song.bpm == song.bpm.rounded() ? "\(Int(song.bpm))" : "\(song.bpm)"
    return DocumentNotice(
      label: label, retained: "\(song.patterns) patterns at \(bpm) BPM retained exactly.",
      guidance: compatibility == .rackExtended
        ? "The song plays here; cabled machines run through the Groovebox source, and editing it in the "
          + "groovebox window keeps the rack's additions here."
        : "The song plays through its own mix; patch a Groovebox output to take that machine through the "
          + "rack. Editing it in the groovebox window loses nothing.")
  }
}
