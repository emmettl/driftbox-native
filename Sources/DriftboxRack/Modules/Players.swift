import DriftboxDSP

// The arpeggiator and the scale and chord players, each a line-for-line port of its file in
// `driftbox/packages/rack/src/modules`. The family's processors are one enum here, behind one case
// of `RackProcessor`, so its modules can be added without touching anyone else's. The arp lives in
// `PlayersArp.swift`.

public enum PlayerProcessor {
  case arp(Arp)
  case scalePlayer(ScalePlayer)
  case chordPlayer(ChordPlayer)

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    switch self {
    case .arp(var module):
      module.process(inlets, outlets, params, context)
      self = .arp(module)
    case .scalePlayer(var module):
      module.process(inlets, outlets, params, context)
      self = .scalePlayer(module)
    case .chordPlayer(var module):
      module.process(inlets, outlets, params, context)
      self = .chordPlayer(module)
    }
  }

  func meter() -> MeterReading? { nil }

  mutating func release() {
    switch self {
    case .arp(let module): module.release()
    case .scalePlayer: break
    case .chordPlayer(let module): module.release()
    }
  }
}

/// JavaScript's arithmetic where Swift's differs, and the scales the players share.
enum PlayerMath {
  /// `Math.min`: NaN if either is, and -0 below +0.
  @_noAllocation
  static func min(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a < b { return a }
    if b < a { return b }
    return a.sign == .minus ? a : b
  }

  /// `Math.max`: NaN if either is, and +0 above -0.
  @_noAllocation
  static func max(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a > b { return a }
    if b > a { return b }
    return a.sign == .minus ? b : a
  }

  /// `x % m` for a whole-numbered `x` and a positive whole `m`: the sign of the dividend, and NaN
  /// for anything not finite. Every remainder in this family is of whole numbers.
  @_noAllocation
  static func remainder(_ x: Double, _ m: Int) -> Double {
    guard x.isFinite else { return .nan }
    guard x > -9.2e18, x < 9.2e18 else { return 0 }
    let rest = Double(Int64(x) % Int64(m))
    // `-12 % 12` is -0 in JavaScript.
    return rest == 0 && x < 0 ? -0.0 : rest
  }

  /// `((x % 12) + 12) % 12`: where a whole number of semitones falls in the octave.
  @_noAllocation
  static func pitchClass(_ x: Double) -> Double { remainder(remainder(x, 12) + 12, 12) }

  /// A twelve-note scale as a bit per semitone above the key, in the order of the Scale param's
  /// labels: the reference's degree lists, which it only ever asks "is this one in it".
  @_noAllocation
  static func presetScale(_ which: Int) -> Int {
    switch which {
    case 0: 0b1010_1011_0101  // major
    case 1: 0b0101_1010_1101  // natural minor
    case 2: 0b1010_1101_0101  // lydian
    case 3: 0b0110_1011_0101  // mixolydian
    case 4: 0b0101_1011_0011  // Spanish / Phrygian dominant
    case 5: 0b0110_1010_1101  // dorian
    case 6: 0b0101_1010_1011  // phrygian
    case 7: 0b1001_1010_1101  // harmonic minor
    case 8: 0b1010_1010_1101  // melodic minor ascending
    case 9: 0b0010_1001_0101  // major pentatonic
    case 10: 0b0100_1010_1001  // minor pentatonic
    case 11: 0b0001_1010_0011  // hemi pentatonic
    default: 0b1111_1111_1111  // chromatic
    }
  }

  /// The scale `which` names — thirteen presets, then Custom, read from the `customScale` data's
  /// first twelve values. A missing or empty custom scale is Major.
  @_noAllocation
  static func scale(_ which: Int, custom: DataBuffer) -> Int {
    if which < 13 { return presetScale(which) }
    guard let samples = custom.samples else { return presetScale(0) }
    var mask = 0
    var note = 0
    while note < 12 && note < custom.count {
      if samples[note] >= 0.5 { mask |= 1 << note }
      note += 1
    }
    return mask != 0 ? mask : presetScale(0)
  }

  /// `degrees.indexOf(relative) !== -1`.
  @_noAllocation
  static func contains(_ mask: Int, _ relative: Double) -> Bool {
    guard relative >= 0, relative < 12 else { return false }
    let semitone = Int(relative)
    return Double(semitone) == relative && mask & (1 << semitone) != 0
  }
}

// MARK: - Scale Player

/// Keeps notes in key: an outside note is moved to the nearest scale tone, the lower on a tie, or
/// filtered out, decided at its gate's rising edge and held for the note.
public struct ScalePlayer {
  var lastGate = 0
  var correction = 0.0
  var allowed = true

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitchIn = inlets[0]
    let gateIn = inlets[1]
    let velocityIn = inlets[2]
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let velocityOut = outlets[2]
    let keyParam = params[0]
    let scaleParam = params[1]
    let filterParam = params[2]

    for i in 0..<frames {
      let gate = gateIn[i] >= 0.5 ? 1 : 0
      if gate == 1 && lastGate == 0 {
        var key = jsRound(Double(keyParam[i]))
        if key < 0 { key = 0 } else if key > 11 { key = 11 }
        var which = jsRound(Double(scaleParam[i]))
        if which < 0 { which = 0 } else if which > 13 { which = 13 }
        let degrees = PlayerMath.scale(Int(which), custom: context.data[0])

        // Rounded once at note-on, so a hair of float error cannot make a C a C sharp; only the
        // correction is kept, so later bend passes untouched.
        let inputNote = jsRound(Double(pitchIn[i]) * 12)
        let relative = PlayerMath.pitchClass(inputNote - key)
        allowed = PlayerMath.contains(degrees, relative)
        correction = 0

        if !allowed && jsRound(Double(filterParam[i])) == 0 {
          // Outward, the lower candidate first: that is the tie-break.
          for distance in 1...12 {
            let lower = PlayerMath.pitchClass(relative - Double(distance))
            if PlayerMath.contains(degrees, lower) {
              correction = -Double(distance)
              allowed = true
              break
            }
            let upper = PlayerMath.remainder(relative + Double(distance), 12)
            if PlayerMath.contains(degrees, upper) {
              correction = Double(distance)
              allowed = true
              break
            }
          }
        }
      }
      lastGate = gate

      pitchOut[i] = Float(Double(pitchIn[i]) + correction / 12)
      let sounding = gate == 1 && allowed
      gateOut[i] = sounding ? 1 : 0
      velocityOut[i] = sounding ? Float(PlayerMath.max(0, PlayerMath.min(1, Double(velocityIn[i])))) : 0
    }
  }
}

// MARK: - Chord Player

/// Turns every incoming note into a chord built from the scale: each source voice owns eight lanes,
/// and each lane plays one note of it. Lanes that land on the same pitch in the same frame — two
/// roots sharing a chord tone — sound once, which the voices agree through scratch they share:
/// voice 0 runs first and clears it.
public struct ChordPlayer {
  static let lanes = 8
  /// The reference sizes its shared scratch to the block, a count and `voices` pitches a frame. Here
  /// it is fixed: enough for 512-frame blocks at the rack's 64 voices, and longer ones at fewer.
  static let sharedDoubles = 512 * (64 + 1)

  let lane: Int
  let voice: Int
  let voices: Int
  /// Eight doubles of chord, then eight of voicing: the reference's two `Float64Array(8)`.
  let chord: UnsafeMutablePointer<Double>
  let voiced: UnsafeMutablePointer<Double>

  init(voice info: VoiceInfo) {
    lane = info.lane
    voice = info.voice
    voices = info.voices
    chord = .allocate(capacity: 16)
    chord.initialize(repeating: 0, count: 16)
    voiced = chord + 8
  }

  func release() { chord.deallocate() }

  @_noAllocation
  static func inScale(_ note: Double, _ key: Double, _ mask: Int) -> Bool {
    PlayerMath.contains(mask, PlayerMath.pitchClass(note - key))
  }

  /// Nearest scale note, lower first so an exact tie agrees with Scale Player.
  @_noAllocation
  static func corrected(_ note: Double, _ key: Double, _ mask: Int) -> Double {
    if inScale(note, key, mask) { return note }
    for distance in 1...12 {
      if inScale(note - Double(distance), key, mask) { return note - Double(distance) }
      if inScale(note + Double(distance), key, mask) { return note + Double(distance) }
    }
    return note
  }

  /// Walk `steps` scale degrees upward from an already-correct root.
  @_noAllocation
  static func scaleNote(_ root: Double, _ steps: Int, _ key: Double, _ mask: Int) -> Double {
    // The reference never leaves this loop for a root that is not a finite number.
    if !root.isFinite { return root }
    var note = root
    var found = 0
    while found < steps {
      note += 1
      if inScale(note, key, mask) { found += 1 }
    }
    return note
  }

  @_noAllocation
  static func contains(_ values: UnsafeMutablePointer<Double>, _ count: Int, _ note: Double) -> Bool {
    for i in 0..<count where values[i] == note { return true }
    return false
  }

  /// Insertion sort: eight values at most, and stable.
  @_noAllocation
  static func sort(_ values: UnsafeMutablePointer<Double>, _ count: Int) {
    var i = 1
    while i < count {
      let value = values[i]
      var at = i
      while at > 0 && values[at - 1] > value {
        values[at] = values[at - 1]
        at -= 1
      }
      values[at] = value
      i += 1
    }
  }

  @_noAllocation
  static func add(_ values: UnsafeMutablePointer<Double>, _ count: Int, _ note: Double, _ direction: Double)
    -> Int
  {
    var note = note
    // Not for an infinite note, which the reference would chase forever.
    if note.isFinite {
      while contains(values, count, note) { note += direction * 12 }
    }
    values[count] = note
    return count + 1
  }

  /// Absolute semitone notes, returning how many of the eight lanes are active.
  @_noAllocation
  func buildChord(
    _ root: Double, _ key: Double, _ mask: Int, _ notes: Int, _ inversion: Int, _ open: Bool, _ octUp: Bool,
    _ octDown: Bool, _ color: Bool, _ alter: Bool
  ) -> Int {
    for tone in 0..<notes { chord[tone] = Self.scaleNote(root, tone * 2, key, mask) }

    // Alter toggles the tertian third; an exotic one moves toward the nearer common third.
    if alter && notes > 1 {
      let interval = PlayerMath.pitchClass(chord[1] - root)
      chord[1] += interval >= 4 ? -1 : 1
    }

    let inverted = Swift.min(Swift.max(0, inversion), notes - 1)
    for lane in 0..<notes {
      let shifted = lane + inverted
      voiced[lane] = chord[shifted % notes] + (shifted >= notes ? 12 : 0)
    }
    // The inversion names the bass but not its octave: keep it within a tritone of the root.
    let bassDistance = voiced[0] - root
    let inversionOctave: Double = bassDistance > 6 ? -12 : bassDistance < -6 ? 12 : 0
    if inversionOctave != 0 {
      for tone in 0..<notes { voiced[tone] += inversionOctave }
    }

    // Open: alternate inner notes up an octave, then back into pitch order.
    if open && notes >= 3 {
      var tone = 1
      while tone < notes - 1 {
        voiced[tone] += 12
        tone += 2
      }
      Self.sort(voiced, notes)
    }

    var count = notes
    if octDown { count = Self.add(voiced, count, root - 12, -1) }
    if octUp { count = Self.add(voiced, count, root + 12, 1) }
    if color { count = Self.add(voiced, count, Self.scaleNote(root, (notes + 1) * 2, key, mask), 1) }
    Self.sort(voiced, count)
    return count
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let pitchIn = inlets[0]
    let gateIn = inlets[1]
    let velocityIn = inlets[2]
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let velocityOut = outlets[2]

    // The shared scratch: a count a frame, then `voices` pitches a frame. It holds as many frames as
    // fit, and a frame past them — only in a block far longer than the rack's — is not de-duplicated.
    let shared = context.voice.shared
    let stride = voices > 0 ? voices : 1
    let kept = shared == nil ? 0 : Swift.min(frames, context.voice.sharedCount / (stride + 1))
    if let shared, voice == 0 {
      for i in 0..<kept { shared[i] = 0 }
    }

    for i in 0..<frames {
      var key = jsRound(Double(params[0][i]))
      if key < 0 { key = 0 } else if key > 11 { key = 11 }
      var which = jsRound(Double(params[1][i]))
      if which < 0 { which = 0 } else if which > 13 { which = 13 }
      let degrees = PlayerMath.scale(Int(which), custom: context.data[0])
      var notes = jsRound(Double(params[2][i]))
      if notes < 1 { notes = 1 } else if notes > 5 { notes = 5 }
      var inversion = jsRound(Double(params[3][i]))
      if inversion < 0 { inversion = 0 } else if inversion > 4 { inversion = 4 }

      let inputSemitone = Double(pitchIn[i]) * 12
      let rounded = jsRound(inputSemitone)
      let root = Self.corrected(rounded, key, degrees)
      let bend = inputSemitone - rounded
      let count = buildChord(
        root, key, degrees, Int(notes), Int(inversion), params[4][i] >= 0.5, params[5][i] >= 0.5,
        params[6][i] >= 0.5, params[7][i] >= 0.5, params[8][i] >= 0.5)
      let active = lane < count && gateIn[i] >= 0.5
      let generated = (lane < count ? voiced[lane] : root) + bend
      pitchOut[i] = Float(generated / 12)

      var unique = active
      if unique, let counts = shared, i < kept {
        let seen = counts + kept
        let used = Int(counts[i])
        let base = i * stride
        for note in 0..<used where abs(seen[base + note] - generated) < 1e-5 {
          // Float32 pitch CV can make one semitone a few millionths apart from two roots.
          unique = false
          break
        }
        if unique && used < voices {
          seen[base + used] = generated
          counts[i] = Double(used + 1)
        }
      }
      gateOut[i] = unique ? 1 : 0
      velocityOut[i] = unique ? Float(PlayerMath.max(0, PlayerMath.min(1, Double(velocityIn[i])))) : 0
    }
  }
}

// MARK: - Definitions

extension RackModules {
  static let playerDefs: [ModuleDef] = [arp, scalePlayer, chordPlayer]

  static func makePlayer(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo) -> PlayerProcessor?
  {
    switch type {
    case "arp": .arp(Arp(sampleRate: sampleRate, id: id))
    case "scale-player": .scalePlayer(ScalePlayer())
    case "chord-player": .chordPlayer(ChordPlayer(voice: voice))
    default: nil
    }
  }

  static let arp: ModuleDef = {
    var def = ModuleDef(
      type: "arp", version: 16, name: "Arp",
      inlets: [
        Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity"), Port("clock", "Clock"),
        Port("reset", "Reset"), Port("start", "Start"), Port("gateCv", "Gate Length CV"),
        Port("velocityCv", "Velocity CV"), Port("rateCv", "Rate CV"), Port("shiftCv", "Octave Shift CV"),
        Port("mod", "Mod"), Port("bend", "Pitch Bend"), Port("aftertouch", "Aftertouch"),
        Port("expression", "Expression"), Port("breath", "Breath"), Port("sustain", "Sustain"),
      ],
      outlets: [
        Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity"), Port("trig", "Trig"),
        Port("start", "Start"), Port("mod", "Mod"), Port("bend", "Pitch Bend"),
        Port("aftertouch", "Aftertouch"),
        Port("expression", "Expression"), Port("breath", "Breath"), Port("sustain", "Sustain"),
        Port("gateVelocity", "Gate / Velocity"),
      ],
      params: [
        ParamDef("source", "Source", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("chord", "Chord", min: 0, max: 7, default: 3, stepped: true),
        ParamDef("octaves", "Octaves", min: 1, max: 4, default: 2, stepped: true),
        ParamDef("mode", "Mode", min: 0, max: 5, default: 0, stepped: true),
        ParamDef("gate", "Gate Length", min: 0, max: 1, default: 0.5),
        ParamDef("hold", "Hold", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("shift", "Octave Shift", min: -3, max: 3, default: 0, stepped: true),
        ParamDef("velocityMode", "Velocity", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("velocity", "Fixed Velocity", min: 0.01, max: 1, default: 0.8),
        ParamDef("timing", "Timing", min: 0, max: 2, default: 0, stepped: true),
        ParamDef("division", "Division", min: 0, max: 15, default: 4, stepped: true),
        ParamDef("rate", "Free Rate", min: 0.1, max: 250, default: 8),
        ParamDef("patternLength", "Pattern Steps", min: 1, max: 16, default: 16, stepped: true),
        ParamDef("insert", "Insert", min: 0, max: 4, default: 0, stepped: true),
        ParamDef("singleRepeat", "Single Note Repeat", min: 0, max: 1, default: 1, stepped: true),
        ParamDef("shuffle", "Shuffle", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("enable", "Arpeggiator", min: 0, max: 1, default: 1, stepped: true),
      ])
    def.poly = false
    def.voiceCollector = true
    def.dataSlots = ["pattern"]
    return def
  }()

  static let scalePlayer: ModuleDef = {
    var def = ModuleDef(
      type: "scale-player", name: "Scale Player",
      inlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      outlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      params: [
        ParamDef("key", "Key", min: 0, max: 11, default: 0, stepped: true),
        ParamDef("scale", "Scale", min: 0, max: 13, default: 0, stepped: true),
        ParamDef("filter", "Wrong Notes", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.dataSlots = ["customScale"]
    return def
  }()

  static let chordPlayer: ModuleDef = {
    var def = ModuleDef(
      type: "chord-player", name: "Chord Player",
      inlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      outlets: [Port("pitch", "V/Oct"), Port("gate", "Gate"), Port("velocity", "Velocity")],
      params: [
        ParamDef("key", "Key", min: 0, max: 11, default: 0, stepped: true),
        ParamDef("scale", "Scale", min: 0, max: 13, default: 0, stepped: true),
        ParamDef("notes", "Notes", min: 1, max: 5, default: 3, stepped: true),
        ParamDef("inversion", "Inversion", min: 0, max: 4, default: 0, stepped: true),
        ParamDef("open", "Open Chords", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("octUp", "Add Oct Up", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("octDown", "Add Oct Down", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("color", "Add Color", min: 0, max: 1, default: 0, stepped: true),
        ParamDef("alter", "Alter", min: 0, max: 1, default: 0, stepped: true),
      ])
    def.voiceExpansion = ChordPlayer.lanes
    def.dataSlots = ["customScale"]
    def.sharedDoubles = ChordPlayer.sharedDoubles
    return def
  }()
}
