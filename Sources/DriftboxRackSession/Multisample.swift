import Foundation

/// One zone of a Multisampler: which recording plays for which notes and velocities, and how it
/// loops. Nine numbers in the module's `zones` data, in this order.
public struct MultisampleZone: Equatable, Sendable {
  public var root: Int
  public var low: Int
  public var high: Int
  public var velocityLow: Double
  public var velocityHigh: Double
  public var loopStart = 0.1
  public var loopEnd = 0.9
  public var loop = false
  public var sampleRate: Double

  public init(
    root: Int, low: Int, high: Int, velocityLow: Double, velocityHigh: Double, loopStart: Double = 0.1,
    loopEnd: Double = 0.9, loop: Bool = false, sampleRate: Double
  ) {
    self.root = root
    self.low = low
    self.high = high
    self.velocityLow = velocityLow
    self.velocityHigh = velocityHigh
    self.loopStart = loopStart
    self.loopEnd = loopEnd
    self.loop = loop
    self.sampleRate = sampleRate
  }

  public static let stride = 9

  public static func pack(_ zones: [MultisampleZone]) -> [Double] {
    zones.flatMap {
      [
        Double($0.root), Double($0.low), Double($0.high), $0.velocityLow, $0.velocityHigh, $0.loopStart,
        $0.loopEnd,
        $0.loop ? 1 : 0, $0.sampleRate,
      ]
    }
  }

  public static func unpack(_ values: [Double]) -> [MultisampleZone] {
    var zones: [MultisampleZone] = []
    var at = 0
    while at + stride <= values.count {
      let v = Array(values[at..<at + stride])
      zones.append(
        MultisampleZone(
          root: Int(v[0]), low: Int(v[1]), high: Int(v[2]), velocityLow: v[3], velocityHigh: v[4],
          loopStart: v[5],
          loopEnd: v[6], loop: v[7] >= 0.5, sampleRate: v[8]))
      at += stride
    }
    return zones
  }
}

/// How a set of recordings maps itself: the reference's `multisample.ts`, held to its own output
/// over a spread of file names by `MultisampleTests`.
public enum Multisample {
  private static let semitones: [String: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns written here, so a failure is a mistake in this file rather than in any input.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }
  private static let numbered = regex("(?:^|[^a-z])(?:midi|note)[ _-]?(\\d{1,3})(?=$|\\D)")
  private static let named = regex("(?:^|[^a-z0-9])([a-g])([#b]?)(-?\\d)(?=$|[^0-9])")
  private static let velocityNumber = regex("(?:^|[^a-z0-9])(?:vel(?:ocity)?|v)[ _-]?(\\d{1,3})(?=$|\\D)")
  private static let dynamic = regex("(?:^|[^a-z])(pp|mp|mf|ff|p|f)(?=$|[^a-z])")
  private static let dynamics: [String: Double] = [
    "pp": 0.16, "p": 0.3, "mp": 0.43, "mf": 0.62, "f": 0.78, "ff": 0.94,
  ]

  private static func groups(_ match: NSTextCheckingResult, in name: String) -> [String] {
    (1..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: name).map { String(name[$0]) } ?? ""
    }
  }

  /// The MIDI note a file name names: `midi 72` or `note60`, or else the last note name in it,
  /// such as `C#4` with C4 60.
  public static func note(_ name: String) -> Int? {
    let whole = NSRange(name.startIndex..., in: name)
    if let match = numbered.firstMatch(in: name, range: whole), let value = Int(groups(match, in: name)[0]) {
      return max(0, min(127, value))
    }
    guard let last = named.matches(in: name, range: whole).last else { return nil }
    let parts = groups(last, in: name)
    let accidental = parts[1] == "#" ? 1 : parts[1].lowercased() == "b" ? -1 : 0
    guard let octave = Int(parts[2]), let semitone = semitones[parts[0].lowercased()] else { return nil }
    let note = (octave + 1) * 12 + semitone + accidental
    return note >= 0 && note <= 127 ? note : nil
  }

  /// The velocity a file name implies: `vel064` or `v127` out of 127, or a dynamic from pp to ff.
  public static func velocity(_ name: String) -> Double? {
    let whole = NSRange(name.startIndex..., in: name)
    if let match = velocityNumber.firstMatch(in: name, range: whole),
      let value = Double(groups(match, in: name)[0])
    {
      return max(0, min(1, value / 127))
    }
    guard let match = dynamic.firstMatch(in: name, range: whole) else { return nil }
    return dynamics[groups(match, in: name)[0].lowercased()]
  }

  /// Zones for a set of recordings: each at the note its name gives, or placed chromatically about
  /// middle C; key ranges meeting halfway between neighbouring roots; recordings sharing a root
  /// layered by velocity, softest lowest, the unmarked above the marked.
  public static func zones(names: [String], sampleRate: Double) -> [MultisampleZone] {
    let start = 60 - (names.count - 1) / 2
    let roots = names.enumerated().map { index, name in note(name) ?? max(0, min(127, start + index)) }
    let unique = Array(Set(roots)).sorted()
    var ranges: [Int: (low: Int, high: Int)] = [:]
    for (index, root) in unique.enumerated() {
      let low = index == 0 ? 0 : (unique[index - 1] + root) / 2 + 1
      let high = index == unique.count - 1 ? 127 : (root + unique[index + 1]) / 2
      ranges[root] = (low, high)
    }
    let velocities = names.map(velocity)
    var layers: [Int: [Int]] = [:]
    for (index, root) in roots.enumerated() { layers[root, default: []].append(index) }
    var bands: [Int: (low: Double, high: Double)] = [:]
    for indices in layers.values {
      let ordered = indices.sorted { a, b in
        switch (velocities[a], velocities[b]) {
        case (nil, nil): return a < b
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?): return left != right ? left < right : a < b
        }
      }
      for (layer, index) in ordered.enumerated() {
        bands[index] =
          ordered.count == 1
          ? (0, 1) : (Double(layer) / Double(ordered.count), Double(layer + 1) / Double(ordered.count))
      }
    }
    return roots.enumerated().map { index, root in
      MultisampleZone(
        root: root, low: ranges[root]?.low ?? 0, high: ranges[root]?.high ?? 127,
        velocityLow: bands[index]?.low ?? 0, velocityHigh: bands[index]?.high ?? 1, sampleRate: sampleRate)
    }
  }

  public static func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let midi = max(0, min(127, note))
    return "\(names[midi % 12])\(midi / 12 - 1)"
  }
}
