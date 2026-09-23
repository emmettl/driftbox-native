#if canImport(SwiftUI) && canImport(AVFoundation)
  import Foundation

  /// A keyboard allocated across the patch's voices: a port of the reference's `Keyboard`. Every
  /// key held goes on a stack and the newest N sound, which at one voice is last-note priority
  /// with legato — a held note comes back when the newer one is let go — and at eight is a
  /// polyphonic allocator that steals the oldest and hands it back. Only what changed is reported.
  struct RackKeyboard {
    struct VoiceState: Equatable {
      var voice: Int
      var note: Int
      var gate: Int
      var velocity: Double
    }

    private(set) var voices: Int
    private var held: [(note: Int, velocity: Double)] = []
    /// The note each voice is sounding, or nil.
    private var sounding: [Int?]
    /// The pitch each voice holds through its release, so a decaying envelope does not also slide.
    private var resting: [Int]
    /// When each voice last fell silent, so the longest idle is taken first and a release rings.
    private var freedAt: [Int]
    private var tick: Int

    init(voices: Int = 1) {
      let count = max(1, min(8, voices))
      self.voices = count
      sounding = Array(repeating: nil, count: count)
      resting = Array(repeating: 36, count: count)
      freedAt = Array(0..<count)
      tick = count
    }

    /// The notes sounding now, for lighting the keys being played.
    var playing: [Int] { sounding.compactMap { $0 } }

    /// A new voice count. Everything stops, and what stopped is reported for the voices that remain.
    mutating func setVoices(_ count: Int) -> [VoiceState] {
      let next = max(1, min(8, count))
      let silenced = allOff()
      self = RackKeyboard(voices: next)
      return silenced.filter { $0.voice < next }
    }

    mutating func down(_ note: Int, velocity: Double) -> [VoiceState] {
      // A key already down is a retrigger rather than a second entry, or the stack would never empty.
      held.removeAll { $0.note == note }
      held.append((note, velocity))
      return reassign(retrigger: note)
    }

    mutating func up(_ note: Int) -> [VoiceState] {
      let before = held.count
      held.removeAll { $0.note == note }
      if held.count == before { return [] }
      return reassign()
    }

    mutating func allOff() -> [VoiceState] {
      held = []
      return reassign()
    }

    /// The newest `voices` keys sound. A voice already playing a wanted note keeps it, so a chord
    /// does not shuffle between voices and retrigger envelopes that should be sustaining.
    private mutating func reassign(retrigger: Int? = nil) -> [VoiceState] {
      let wanted = held.suffix(voices)
      var changes: [VoiceState] = []
      var keeping = Set<Int>()
      var placed = Set<Int>()
      for entry in wanted {
        if let voice = sounding.firstIndex(of: entry.note) {
          keeping.insert(voice)
          placed.insert(entry.note)
          if entry.note == retrigger {
            changes.append(VoiceState(voice: voice, note: entry.note, gate: 1, velocity: entry.velocity))
          }
        }
      }
      // Free voices, longest idle first, so a note just let go keeps ringing while there is
      // somewhere else to put the new one.
      var free = sounding.indices.filter { voice in
        guard !keeping.contains(voice) else { return false }
        return sounding[voice].map { !placed.contains($0) } ?? true
      }
      .sorted { freedAt[$0] < freedAt[$1] }
      for entry in wanted where !placed.contains(entry.note) {
        guard !free.isEmpty else { continue }
        let voice = free.removeFirst()
        sounding[voice] = entry.note
        resting[voice] = entry.note
        placed.insert(entry.note)
        changes.append(VoiceState(voice: voice, note: entry.note, gate: 1, velocity: entry.velocity))
      }
      for voice in free where sounding[voice] != nil {
        sounding[voice] = nil
        freedAt[voice] = tick
        tick += 1
        changes.append(VoiceState(voice: voice, note: resting[voice], gate: 0, velocity: 0))
      }
      return changes
    }

    /// Computer keys to semitones: two octaves under the hands, as the reference's rack has them.
    static let keyMap: [Character: Int] = {
      let white = [0, 2, 4, 5, 7, 9, 11]
      let black = [1, 3, 6, 8, 10]
      var map: [Character: Int] = [:]
      for (keys, semitones) in [
        ("zxcvbnm", white), ("sdghj", black), ("qwertyu", white.map { $0 + 12 }),
        ("23567", black.map { $0 + 12 }),
      ] {
        for (key, semitone) in zip(keys, semitones) { map[key] = semitone }
      }
      return map
    }()

    /// Where the keys start: C2, which is 0 V on every pitch inlet in the rack.
    static let root = 36

    /// `C2`, with 60 as C4.
    static func name(_ note: Int) -> String {
      let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
      let octave = Int((Double(note) / 12).rounded(.down)) - 1
      return "\(names[((note % 12) + 12) % 12])\(octave)"
    }
  }
#endif
