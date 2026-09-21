// A song, as plain values. A port of the types in `driftbox/packages/engine/src/pattern.ts` and
// `bass.ts`; the reasoning for each field lives there.
//
// Where the reference has an optional field that its own decoder always fills in, the field here
// is simply present, and "absent" is the empty value. What the decoder leaves out — track
// lengths, flams, the PCF lane, automation — the encoder leaves out again on the same rule, so a
// document survives the round trip to the byte.

/// Off, on, or accented. The machines only ever had these three.
public enum StepValue: UInt8, Equatable, Sendable {
  case off = 0
  case on = 1
  case accent = 2
}

/// A 303 step. A paused step may still hold a pitch, for the next note to glide out of.
public struct BassStep: Equatable, Sendable {
  /// Semitones above the root, or nil when no pitch has ever been assigned.
  public var note: Double?
  public var accent: Bool
  /// Hold through the next step and glide into it, rather than stopping.
  public var slide: Bool
  /// Whether the pitch sounds. Nil preserves the original `note != nil` meaning.
  public var gate: Bool?

  public init(note: Double? = nil, accent: Bool = false, slide: Bool = false, gate: Bool? = nil) {
    self.note = note
    self.accent = accent
    self.slide = slide
    self.gate = gate
  }

  public static let rest = BassStep()

  /// Whether the step strikes a note.
  public var sounds: Bool { note != nil && gate != false }
}

public struct Pattern: Equatable, Sendable {
  public var id: String
  public var name: String
  /// Steps per bar, 1...64.
  public var length: Int
  /// Voice id to its steps. A voice with no entry never fires.
  public var tracks = OrderedMap<[StepValue]>()
  /// Drum lanes that loop shorter than the pattern. Absent means the pattern's own length.
  public var trackLengths = OrderedMap<Int>()
  /// Bass voice id to its line.
  public var bass = OrderedMap<[BassStep]>()
  /// 909 flam marks, parallel to the drum tracks.
  public var flams = OrderedMap<[Bool]>()
  /// Pattern-controlled filter strikes for the song-wide insert.
  public var pcf: [StepValue]?

  public init(id: String, name: String, length: Int = 16) {
    self.id = id
    self.name = name
    self.length = length
  }
}

public struct Kit: Equatable, Sendable {
  public var params = OrderedMap<VoiceParams>()
  public var bass = OrderedMap<BassParams>()
  public var sends = OrderedMap<SendLevels>()
  /// Per-voice swing, as an offset from the song's own. 0.5 is no offset.
  public var swing = OrderedMap<Double>()
  /// Global TR-909 flam spacing, 0...1.
  public var flam: Double?

  public init() {}
}

/// The four machines a chain entry can choose a clip for. The order is the reference's
/// `CLIP_SLOTS`, and it is the order they are consulted in.
public enum ClipSlot: Int, CaseIterable, Equatable, Sendable {
  case tr808, tr909, bassA, bassB

  public var name: String {
    switch self {
    case .tr808: "tr808"
    case .tr909: "tr909"
    case .bassA: "303.a"
    case .bassB: "303.b"
    }
  }

  /// The lane a voice belongs to. An unknown voice belongs to none, and follows the section's
  /// whole pattern, so an older reader never steals it into the wrong machine.
  public init?(voiceId: String) {
    if voiceId == "303.a" {
      self = .bassA
    } else if voiceId == "303.b" {
      self = .bassB
    } else if voiceId.hasPrefix("808.") {
      self = .tr808
    } else if voiceId.hasPrefix("909.") {
      self = .tr909
    } else {
      return nil
    }
  }
}

/// A pattern id per machine, where one has been chosen.
public struct ClipSelection: Equatable, Sendable {
  var ids: [String?] = [nil, nil, nil, nil]

  public init() {}

  public subscript(slot: ClipSlot) -> String? {
    get { ids[slot.rawValue] }
    set { ids[slot.rawValue] = newValue }
  }

  public var isEmpty: Bool { ids.allSatisfy { $0 == nil } }
}

/// One entry in the arrangement: a pattern, and how many bars it holds for.
public struct ChainStep: Equatable, Sendable {
  /// The whole-groove fallback. A clip replaces just one machine's material.
  public var pattern: String
  public var clips = ClipSelection()
  /// Bars. At least 1.
  public var `repeat`: Int

  public init(pattern: String, repeat: Int = 1) {
    self.pattern = pattern
    self.repeat = `repeat`
  }
}

public enum AutomationInterpolation: Equatable, Sendable {
  case hold, linear
}

public struct AutomationPoint: Equatable, Sendable {
  /// Absolute arrangement bar, zero based.
  public var bar: Int
  /// Step within that bar, zero based.
  public var index: Int
  public var value: Double

  public init(bar: Int, index: Int, value: Double) {
    self.bar = bar
    self.index = index
    self.value = value
  }
}

/// One recordable parameter over the song timeline. Targets are stable strings — see
/// `AutomationTarget` — and a lane this build does not understand is carried, not dropped.
public struct AutomationLane: Equatable, Sendable {
  public var target: String
  public var interpolation: AutomationInterpolation
  public var points: [AutomationPoint]

  public init(target: String, interpolation: AutomationInterpolation, points: [AutomationPoint]) {
    self.target = target
    self.interpolation = interpolation
    self.points = points
  }
}

public struct Song: Equatable, Sendable {
  public var bpm: Double
  public var swing: Double
  /// Which scene the song was written to be seen with. Carried, never interpreted here.
  public var visual: String?
  public var patterns: [Pattern]
  /// The arrangement, in play order, looping at the end. Empty plays the first pattern for ever.
  public var chain: [ChainStep]
  public var kit: Kit
  public var fx: FxParams
  public var automation: [AutomationLane]

  public init(
    bpm: Double = 120, swing: Double = 0, visual: String? = nil, patterns: [Pattern],
    chain: [ChainStep] = [], kit: Kit = Kit(), fx: FxParams = FxParams(),
    automation: [AutomationLane] = []
  ) {
    self.bpm = bpm
    self.swing = swing
    self.visual = visual
    self.patterns = patterns
    self.chain = chain
    self.kit = kit
    self.fx = fx
    self.automation = automation
  }
}
