// Editing a song: the pattern list, the transforms ReBirth put on a menu, the chain. A port of the
// editing half of `driftbox/packages/engine/src/pattern.ts`. Every edit is a pure function of a
// value, so undo is free and a host driving the engine gets the same operations a sequencer does.
// Held to the reference's own results in `conformance/fixtures/edits.json`.

/// A deterministic stream of 0..<1, for the transforms that want chance.
public typealias RandomSource = () -> Double

extension Song {
  /// An id nothing else is using, derived from `base`. Ids are stable keys — the chain refers to
  /// them — so they are generated once and never renamed.
  public func uniquePatternId(_ base: String = "pattern") -> String {
    let taken = Set(patterns.map { $0.id })
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
  }

  func uniquePatternName(_ base: String) -> String {
    let taken = Set(patterns.map { $0.name })
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
  }

  public func addingPattern(length: Int = 16) -> (song: Song, id: String) {
    let id = uniquePatternId("pattern-\(patterns.count + 1)")
    let name = uniquePatternName("Pattern \(patterns.count + 1)")
    var out = self
    var pattern = Pattern(id: id, name: name, length: length)
    pattern.bass = OrderedMap()
    out.patterns.append(pattern)
    return (out, id)
  }

  /// A copy of a pattern, everything in it, placed after the original.
  public func duplicatingPattern(_ id: String) -> (song: Song, id: String) {
    guard let index = patterns.firstIndex(where: { $0.id == id }) else { return (self, id) }
    var copy = patterns[index]
    copy.id = uniquePatternId("\(copy.id)-copy")
    copy.name = uniquePatternName("\(copy.name) copy")
    var out = self
    out.patterns.insert(copy, at: index + 1)
    return (out, copy.id)
  }

  public func renamingPattern(_ id: String, to name: String) -> Song {
    // `String.prototype.trim` — no Foundation here.
    let scalars = name.unicodeScalars
    func blank(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace || scalar.value == 0xFEFF }
    guard let first = scalars.firstIndex(where: { !blank($0) }),
      let last = scalars.lastIndex(where: { !blank($0) })
    else { return self }
    let trimmed = String(scalars[first...last])
    var out = self
    for index in out.patterns.indices where out.patterns[index].id == id {
      out.patterns[index].name = trimmed
    }
    return out
  }

  /// Remove a pattern and every reference to it in the arrangement. Refuses to remove the last.
  public func removingPattern(_ id: String) -> Song {
    guard patterns.count > 1, patterns.contains(where: { $0.id == id }) else { return self }
    var out = self
    out.patterns.removeAll { $0.id == id }
    out.chain = chain.filter { $0.pattern != id }.map { step in
      var step = step
      for slot in ClipSlot.allCases where step.clips[slot] == id { step.clips[slot] = nil }
      return step
    }
    return out
  }

  // MARK: The chain

  public func appendingToChain(_ patternId: String) -> Song {
    var out = self
    out.chain.append(ChainStep(pattern: patternId))
    return out
  }

  public func removingFromChain(at index: Int) -> Song {
    guard chain.indices.contains(index) else { return self }
    var out = self
    out.chain.remove(at: index)
    return out
  }

  public func settingChainRepeat(at index: Int, to repeat: Int) -> Song {
    guard chain.indices.contains(index) else { return self }
    var out = self
    out.chain[index].repeat = max(1, min(64, `repeat`))
    return out
  }

  public func settingChainPattern(at index: Int, to patternId: String) -> Song {
    guard chain.indices.contains(index) else { return self }
    var out = self
    out.chain[index].pattern = patternId
    return out
  }

  public func movingChainEntry(at index: Int, by delta: Int) -> Song {
    let to = index + delta
    guard chain.indices.contains(index), chain.indices.contains(to) else { return self }
    var out = self
    let moved = out.chain.remove(at: index)
    out.chain.insert(moved, at: to)
    return out
  }
}

// MARK: - Transforms

/// `values` over `length` slots, moved round by `delta`: positive is later.
private func rotated<T>(_ values: [T], length: Int, delta: Int, fallback: T) -> [T] {
  guard length > 0 else { return [] }
  let source = (0..<length).map { $0 < values.count ? values[$0] : fallback }
  let offset = wrap(delta, length)
  return (0..<length).map { source[(($0 - offset) % length + length) % length] }
}

/// Fisher–Yates, drawing from `random` exactly as the reference does.
private func shuffled<T>(_ values: [T], _ random: RandomSource) -> [T] {
  var next = values
  var index = next.count - 1
  while index > 0 {
    let swap = min(index, Int((random() * Double(index + 1)).rounded(.down)))
    next.swapAt(index, swap)
    index -= 1
  }
  return next
}

extension Pattern {
  /// Move one drum lane round its loop. Its flam marks go with it.
  public func rotatingTrack(_ voiceId: String, by delta: Int) -> Pattern {
    guard let track = tracks[voiceId] else { return self }
    let loop = trackLength(voiceId)
    var out = self
    var next = (0..<length).map { $0 < track.count ? track[$0] : .off }
    for (index, value) in rotated(track, length: loop, delta: delta, fallback: .off).enumerated() {
      next[index] = value
    }
    out.tracks[voiceId] = next
    if let marks = flams[voiceId] {
      var nextMarks = (0..<length).map { $0 < marks.count && marks[$0] }
      for (index, value) in rotated(marks, length: loop, delta: delta, fallback: false).enumerated() {
        nextMarks[index] = value
      }
      out.flams[voiceId] = nextMarks
    }
    return out
  }

  public func rotatingBassLine(_ voiceId: String, by delta: Int) -> Pattern {
    guard let line = bass[voiceId] else { return self }
    var out = self
    out.bass[voiceId] = rotated(line, length: length, delta: delta, fallback: .rest)
    return out
  }

  public func transposingBassLine(_ voiceId: String, by semitones: Int) -> Pattern {
    guard let line = bass[voiceId] else { return self }
    var out = self
    out.bass[voiceId] = (0..<length).map { index in
      var step = index < line.count ? line[index] : .rest
      if let note = step.note { step.note = max(0, min(24, note + Double(semitones))) }
      return step
    }
    return out
  }

  /// New material for a lane, within its loop; what lies beyond the loop is kept.
  public func randomisingTrack(_ voiceId: String, random: RandomSource) -> Pattern {
    let loop = trackLength(voiceId)
    let existing = tracks[voiceId] ?? []
    var out = self
    out.tracks[voiceId] = (0..<length).map { index in
      if index >= loop { return index < existing.count ? existing[index] : .off }
      let value = random()
      return value < 0.58 ? .off : value < 0.88 ? .on : .accent
    }
    out.flams[voiceId] = nil
    return out
  }

  public func randomisingBassLine(_ voiceId: String, random: RandomSource) -> Pattern {
    var out = self
    out.bass[voiceId] = (0..<length).map { _ in
      if random() < 0.46 { return .rest }
      let note = min(24, (random() * 25).rounded(.down))
      return BassStep(note: note, accent: random() < 0.24, slide: random() < 0.18)
    }
    return out
  }

  /// Reorder the material already in a lane: the number of hits, accents and rests is kept.
  public func alteringTrack(_ voiceId: String, random: RandomSource) -> Pattern {
    guard let track = tracks[voiceId] else { return self }
    let loop = trackLength(voiceId)
    let marks = flams[voiceId]
    let source = (0..<loop).map { index in
      (
        value: index < track.count ? track[index] : StepValue.off,
        flam: marks.map { index < $0.count && $0[index] } ?? false
      )
    }
    let altered = shuffled(source, random)
    var out = self
    var next = (0..<length).map { $0 < track.count ? track[$0] : .off }
    for (index, step) in altered.enumerated() { next[index] = step.value }
    out.tracks[voiceId] = next
    if let marks {
      var nextMarks = (0..<length).map { $0 < marks.count && marks[$0] }
      for (index, step) in altered.enumerated() { nextMarks[index] = step.flam }
      out.flams[voiceId] = nextMarks
    }
    return out
  }

  public func alteringBassLine(_ voiceId: String, random: RandomSource) -> Pattern {
    guard let line = bass[voiceId] else { return self }
    var out = self
    out.bass[voiceId] = shuffled((0..<length).map { $0 < line.count ? line[$0] : .rest }, random)
    return out
  }

  public func clearingTrack(_ voiceId: String) -> Pattern {
    var out = self
    out.tracks[voiceId] = nil
    out.trackLengths[voiceId] = nil
    out.flams[voiceId] = nil
    return out
  }

  public func clearingBassLine(_ voiceId: String) -> Pattern {
    var out = self
    out.bass[voiceId] = nil
    return out
  }

  /// Set one drum voice's loop length. A full-length lane stays unwritten.
  public func settingTrackLength(_ voiceId: String, to length: Int) -> Pattern {
    var out = self
    let clamped = max(1, min(self.length, length))
    out.trackLengths[voiceId] = clamped == self.length ? nil : clamped
    return out
  }

  /// Toggle a 909 flam. Enabling one on a rest also creates the hit it articulates.
  public func togglingFlam(_ voiceId: String, at step: Int) -> Pattern {
    let index = wrap(step, trackLength(voiceId))
    let existing = flams[voiceId] ?? []
    var marks = (0..<length).map { $0 < existing.count && existing[$0] }
    marks[index].toggle()
    let existingTrack = tracks[voiceId] ?? []
    var track = (0..<length).map { $0 < existingTrack.count ? existingTrack[$0] : .off }
    if marks[index], track[index] == .off { track[index] = .on }
    var out = self
    out.tracks[voiceId] = track
    out.flams[voiceId] = marks
    return out
  }
}
