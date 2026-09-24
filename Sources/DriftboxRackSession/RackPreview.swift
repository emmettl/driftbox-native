/// What the Chord Player and the Arp faces preview: ports of the reference's
/// `chord-player-display.ts` and `arp-display.ts`, held to them over a grid of settings by
/// `RackPreviewTests`. Shared, so the Mac's faces and the canvas's preview the same chords.
public enum RackPreview {
  /// The reference's `scalePlayerMask`: which of the twelve notes from the key a scale has, with an
  /// empty custom map falling back to major.
  public static let presets: [[Int]] = [
    [0, 2, 4, 5, 7, 9, 11], [0, 2, 3, 5, 7, 8, 10], [0, 2, 4, 6, 7, 9, 11], [0, 2, 4, 5, 7, 9, 10],
    [0, 1, 4, 5, 7, 8, 10], [0, 2, 3, 5, 7, 9, 10], [0, 1, 3, 5, 7, 8, 10], [0, 2, 3, 5, 7, 8, 11],
    [0, 2, 3, 5, 7, 9, 11], [0, 2, 4, 7, 9], [0, 3, 5, 7, 10], [0, 1, 5, 7, 8],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  ]

  public static func scaleMask(_ scale: Int, _ custom: [Double]) -> [Double] {
    let which = max(0, min(13, scale))
    let degrees: [Int] =
      which < presets.count
      ? presets[which]
      : custom.contains(where: { $0 >= 0.5 }) ? custom.indices.filter { custom[$0] >= 0.5 } : presets[0]
    return (0..<12).map { degrees.contains($0) ? 1 : 0 }
  }

  public struct Chord {
    public var key = 0
    public var scale = 0
    public var custom: [Double] = []
    public var notes = 3
    public var inversion = 0
    public var open = false
    public var octUp = false
    public var octDown = false
    public var color = false
    public var alter = false

    public init(
      key: Int = 0, scale: Int = 0, custom: [Double] = [], notes: Int = 3, inversion: Int = 0,
      open: Bool = false, octUp: Bool = false, octDown: Bool = false, color: Bool = false, alter: Bool = false
    ) {
      self.key = key
      self.scale = scale
      self.custom = custom
      self.notes = notes
      self.inversion = inversion
      self.open = open
      self.octUp = octUp
      self.octDown = octDown
      self.color = color
      self.alter = alter
    }
  }

  /// The notes a Chord Player setting voices, low to high, in semitones from C.
  public static func chord(_ options: Chord) -> [Int] {
    let key = max(0, min(11, options.key))
    let mask = scaleMask(options.scale, options.custom)
    func relative(_ note: Int) -> Int { ((note - key) % 12 + 12) % 12 }
    func inScale(_ note: Int) -> Bool { mask[relative(note)] >= 0.5 }
    func corrected(_ note: Int) -> Int {
      if inScale(note) { return note }
      for distance in 1...12 {
        if inScale(note - distance) { return note - distance }
        if inScale(note + distance) { return note + distance }
      }
      return note
    }
    let root = corrected(key)
    func scaleNote(_ steps: Int) -> Int {
      var note = root
      var found = 0
      while found < steps {
        note += 1
        if inScale(note) { found += 1 }
      }
      return note
    }
    let notes = max(1, min(5, options.notes))
    var chord = (0..<notes).map { scaleNote($0 * 2) }
    if options.alter && notes > 1 {
      // The third, a semitone the other way: a major third minor and a minor one major.
      chord[1] += ((chord[1] - root) % 12 + 12) % 12 >= 4 ? -1 : 1
    }
    let inversion = min(max(0, options.inversion), notes - 1)
    var voiced = (0..<notes).map { lane in
      let shifted = lane + inversion
      return chord[shifted % notes] + (shifted >= notes ? 12 : 0)
    }
    let bassDistance = voiced[0] - root
    let inversionOctave = bassDistance > 6 ? -12 : bassDistance < -6 ? 12 : 0
    if inversionOctave != 0 { voiced = voiced.map { $0 + inversionOctave } }
    if options.open && notes >= 3 {
      var tone = 1
      while tone < notes - 1 {
        voiced[tone] += 12
        tone += 2
      }
      voiced.sort()
    }
    func add(_ start: Int, _ direction: Int) {
      var note = start
      while voiced.contains(note) { note += direction * 12 }
      voiced.append(note)
    }
    if options.octDown { add(root - 12, -1) }
    if options.octUp { add(root + 12, 1) }
    if options.color { add(scaleNote((notes + 1) * 2), 1) }
    return voiced.sorted()
  }

  public struct ArpStep: Equatable, Sendable {
    public var label: String
    public var octave: Int

    public init(label: String, octave: Int) {
      self.label = label
      self.octave = octave
    }
  }

  public static let arpChords: [[Int]] = [
    [0], [0, 7], [0, 4, 7], [0, 3, 7], [0, 4, 7, 11], [0, 3, 7, 10], [0, 5, 7], [0, 3, 6],
  ]

  /// Which note of `length` the figure is on at `step`, by mode: up, down, up and down, down
  /// and up, a scatter, and up again.
  public static func direction(_ step: Int, _ length: Int, _ mode: Int) -> Int {
    if length <= 1 { return 0 }
    switch mode {
    case 1: return length - 1 - step % length
    case 2:
      let cycle = length * 2 - 2
      let at = step % cycle
      return at < length ? at : cycle - at
    case 3:
      let cycle = length * 2 - 2
      let at = step % cycle
      return at < length ? length - 1 - at : at - length + 1
    case 4: return (step * 5 + 3) % length
    default: return step % length
    }
  }

  /// The figure an Arp walks, before any insert: intervals from the root, or played lanes.
  public static func arp(source: Int, chord: Int, octaves: Int, mode: Int, shift: Int, steps: Int = 16)
    -> [ArpStep]
  {
    let played = source >= 1
    let octaves = max(1, min(4, octaves))
    let shift = max(-3, min(3, shift))
    let mode = max(0, min(5, mode))
    let base = played ? Array(0..<8) : arpChords[max(0, min(arpChords.count - 1, chord))]
    let length = base.count * octaves
    return (0..<max(1, steps)).map { step in
      let at = direction(step, length, mode)
      let octave = at / base.count + shift
      if played { return ArpStep(label: "\(base[at % base.count] + 1)", octave: octave) }
      let interval = base[at % base.count] + 12 * octave
      return ArpStep(label: interval > 0 ? "+\(interval)" : "\(interval)", octave: octave)
    }
  }

  /// The figure with the Arp's insert: alternating with the lowest or highest note, or three
  /// forward one back, or four forward two back.
  public static func arp(
    source: Int, chord: Int, octaves: Int, mode: Int, shift: Int, insert: Int, steps: Int = 16
  )
    -> [ArpStep]
  {
    let count = max(1, steps)
    let insert = max(0, min(4, insert))
    let ordinary = arp(
      source: source, chord: chord, octaves: octaves, mode: mode, shift: shift, steps: count + 8)
    if insert == 0 { return Array(ordinary.prefix(count)) }
    if insert == 1 || insert == 2 {
      let high = insert == 2
      let anchor: ArpStep
      if source >= 1 {
        anchor = ArpStep(label: high ? "hi" : "lo", octave: 0)
      } else {
        let octaves = max(1, min(4, octaves))
        let tones = arpChords[max(0, min(arpChords.count - 1, chord))].count
        let ascending = arp(
          source: source, chord: chord, octaves: octaves, mode: 0, shift: shift, steps: tones * octaves)
        anchor = ascending.dropFirst().reduce(ascending[0]) { best, candidate in
          let value = Int(candidate.label) ?? 0
          let bestValue = Int(best.label) ?? 0
          return high ? (value > bestValue ? candidate : best) : (value < bestValue ? candidate : best)
        }
      }
      var at = 0
      return (0..<count).map { index in
        guard index % 2 == 0 else { return anchor }
        defer { at += 1 }
        return ordinary[at]
      }
    }
    let forward = insert == 3 ? 3 : 4
    let back = insert == 3 ? 1 : 2
    var at = 0
    var phase = 1
    return (0..<count).map { _ in
      let step = ordinary[at]
      if phase >= forward {
        at = max(0, at - back)
        phase = 1
      } else {
        at += 1
        phase += 1
      }
      return step
    }
  }
}
