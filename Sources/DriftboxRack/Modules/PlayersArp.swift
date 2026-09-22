import DriftboxDSP

/// One inlet's voices as a collector sees them, or the plain inlet as its only voice when the graph
/// gave no collector view: the reference's `voiceInlets?.[n] ?? [inlets[n]]`. A voice past the end
/// is nil, as an array index past the end is `undefined`.
struct ArpLanes {
  let lanes: Slots?
  let single: UnsafeMutablePointer<Float>

  var count: Int {
    @_noAllocation get { lanes?.count ?? 1 }
  }

  @_noAllocation
  func at(_ voice: Int) -> UnsafeMutablePointer<Float>? {
    if let lanes { return voice >= 0 && voice < lanes.count ? lanes[voice] : nil }
    return voice == 0 ? single : nil
  }
}

/// Turns a chord into one running line: built from a root, or collected from the notes played at
/// its inputs, walked across octaves by mode and rhythm pattern, clocked from a cable, the tempo or
/// its own rate. A port of `arp.ts`.
public struct Arp {
  static let voiceLimit = 64
  static let figureLimit = 256

  let sampleRate: Double
  let trigSamples: Double
  var random: RackRandom

  var step = 0
  var started = false
  var rising = true
  var lastClock = 0
  var lastReset = 0
  var held = 0.0
  var heldVelocity = 1.0
  var gateLeft = 0.0
  var tied = false
  var trigLeft = 0.0
  var since = 0.0
  var interval = 0.0
  var internalLeft = 0.0
  var timingWas = 0
  var tempoPosition = 0.0
  var tempoDelay = 0.0
  var patternStep = 0
  var patternStarted = false
  var insertPhase = 0
  var insertWas = 0
  var singlePitchWas = Double.nan
  var enableWas = true
  var bypassGateWas = 0
  var bypassVoice = -1
  var bypassPitch = 0.0
  var bypassVelocity = 0.0
  var lastStart = 0
  var startAllowed = false
  var startGateLeft = 0.0
  var startGateTied = false
  var cycleStep = 0
  var cycleRising = true
  var cycleInsertPhase = 1
  var randomCycle = 0

  // Per source voice, surviving between blocks: Hold latches by voice.
  let gateWas: UnsafeMutablePointer<UInt8>
  let order: UnsafeMutablePointer<UInt32>
  let latched: UnsafeMutablePointer<UInt8>
  let latchedPitch: UnsafeMutablePointer<Float>
  let latchedVelocity: UnsafeMutablePointer<Float>
  var orderClock = 0.0
  var activeCount = 0
  var playedWas = false

  // The figure: sixty-four voices over up to four octaves. Float32, as the reference's are.
  let figurePitch: UnsafeMutablePointer<Float>
  let figureVelocity: UnsafeMutablePointer<Float>
  let figureOrder: UnsafeMutablePointer<UInt32>

  init(sampleRate: Double, id: String) {
    random = RackRandom(seed: id)
    self.sampleRate = sampleRate > 0 ? sampleRate : 44100
    trigSamples = Swift.max(1, jsRound(self.sampleRate * 0.001))
    gateWas = .allocate(capacity: Self.voiceLimit)
    gateWas.initialize(repeating: 0, count: Self.voiceLimit)
    order = .allocate(capacity: Self.voiceLimit)
    order.initialize(repeating: 0, count: Self.voiceLimit)
    latched = .allocate(capacity: Self.voiceLimit)
    latched.initialize(repeating: 0, count: Self.voiceLimit)
    latchedPitch = .allocate(capacity: Self.voiceLimit)
    latchedPitch.initialize(repeating: 0, count: Self.voiceLimit)
    latchedVelocity = .allocate(capacity: Self.voiceLimit)
    latchedVelocity.initialize(repeating: 0, count: Self.voiceLimit)
    figurePitch = .allocate(capacity: Self.figureLimit)
    figurePitch.initialize(repeating: 0, count: Self.figureLimit)
    figureVelocity = .allocate(capacity: Self.figureLimit)
    figureVelocity.initialize(repeating: 0, count: Self.figureLimit)
    figureOrder = .allocate(capacity: Self.figureLimit)
    figureOrder.initialize(repeating: 0, count: Self.figureLimit)
  }

  func release() {
    gateWas.deallocate()
    order.deallocate()
    latched.deallocate()
    latchedPitch.deallocate()
    latchedVelocity.deallocate()
    figurePitch.deallocate()
    figureVelocity.deallocate()
    figureOrder.deallocate()
  }

  /// The Root source's chord shapes, in semitones: how many notes `which` has.
  @_noAllocation
  static func chordLength(_ which: Int) -> Int {
    switch which {
    case 0: 1
    case 1: 2
    case 4, 5: 4
    default: 3
    }
  }

  /// Note `note` of chord shape `which`: Oct, 5th, Maj, Min, Maj7, Min7, Sus4, Dim.
  @_noAllocation
  static func chordNote(_ which: Int, _ note: Int) -> Int {
    if note == 0 { return 0 }
    switch which {
    case 1: return 7
    case 2: return note == 1 ? 4 : 7
    case 3: return note == 1 ? 3 : 7
    case 4: return note == 1 ? 4 : note == 2 ? 7 : 11
    case 5: return note == 1 ? 3 : note == 2 ? 7 : 10
    case 6: return note == 1 ? 5 : 7
    default: return note == 1 ? 3 : 6
    }
  }

  /// Beat lengths of the Division labels, in the order a patch stores them.
  @_noAllocation
  static func divisionBeats(_ at: Int) -> Double {
    switch at {
    case 0: 2
    case 1: 1
    case 2: 0.5
    case 3: 1.0 / 3
    case 4: 0.25
    case 5: 1.0 / 6
    case 6: 0.125
    case 7: 1.0 / 12
    case 8: 1.0 / 16
    case 9: 1.0 / 32
    case 10: 3
    case 11: 4.0 / 3
    case 12: 1.5
    case 13: 2.0 / 3
    case 14: 0.75
    default: 0.375
    }
  }

  @_noAllocation
  func patternEnabled(_ step: Int, _ pattern: DataBuffer) -> Bool {
    guard let samples = pattern.samples else { return true }
    return step >= pattern.count || samples[step] >= 0.5
  }

  @_noAllocation
  mutating func internalInterval(
    _ timing: Int, _ division: Double, _ rate: Double, _ shuffle: Bool, _ transport: Transport
  ) -> Double {
    if timing == 2 {
      return PlayerMath.max(2, jsRound(sampleRate / PlayerMath.max(0.1, PlayerMath.min(250, rate))))
    }
    let at = Int(PlayerMath.max(0, PlayerMath.min(15, jsRound(division))))
    let tempo = transport.tempo > 0 ? transport.tempo : 120
    let stepBeats = Self.divisionBeats(at)
    let nextPosition = tempoPosition + stepBeats
    let sixteenth = jsRound(nextPosition * 4)
    let onSixteenth = abs(nextPosition - sixteenth / 4) < 1e-7
    let amount = shuffle ? PlayerMath.max(0, PlayerMath.min(1, transport.shuffle)) : 0
    // Shuffle delays the odd sixteenths; the next event subtracts the delay, so pairs swing rather
    // than the whole line slowing.
    let nextDelay = onSixteenth && abs(PlayerMath.remainder(sixteenth, 2)) == 1 ? amount / 8 : 0
    let intervalBeats = stepBeats + nextDelay - tempoDelay
    tempoPosition = nextPosition
    tempoDelay = nextDelay
    return PlayerMath.max(2, jsRound(intervalBeats * sampleRate * 60 / tempo))
  }

  @_noAllocation
  func clearLatch() {
    latched.update(repeating: 0, count: Self.voiceLimit)
  }

  /// The notes held (or latched) now, into the figure, without duplicates, in pitch order — or in the
  /// order they were pressed, for Manual. Returns how many.
  @_noAllocation
  func collectPlayed(
    _ pitchVoices: ArpLanes, _ velocityVoices: ArpLanes, _ voices: Int, _ frame: Int, _ hold: Bool,
    _ manual: Bool
  ) -> Int {
    var count = 0
    for voice in 0..<voices {
      let use = hold ? latched[voice] == 1 : gateWas[voice] == 1
      if !use { continue }
      let pitch =
        gateWas[voice] == 1
        ? (pitchVoices.at(voice).map { Double($0[frame]) } ?? Double(latchedPitch[voice]))
        : Double(latchedPitch[voice])
      let velocity =
        gateWas[voice] == 1
        ? (velocityVoices.at(voice).map { Double($0[frame]) } ?? Double(latchedVelocity[voice]))
        : Double(latchedVelocity[voice])

      // Several roots upstream can make the same chord tone; it is one note of the figure.
      var duplicate = -1
      for at in 0..<count where abs(Double(figurePitch[at]) - pitch) < 1e-5 {
        duplicate = at
        break
      }
      if duplicate >= 0 {
        figureVelocity[duplicate] = Float(PlayerMath.max(Double(figureVelocity[duplicate]), velocity))
        continue
      }

      figurePitch[count] = Float(pitch)
      figureVelocity[count] = Float(velocity > 0 ? PlayerMath.min(1, velocity) : 1)
      figureOrder[count] = order[voice]
      count += 1
    }

    // Insertion sort, stable, in place.
    var i = 1
    while i < count {
      let pitch = figurePitch[i]
      let velocity = figureVelocity[i]
      let noteOrder = figureOrder[i]
      var at = i
      while at > 0 {
        let before = manual ? figureOrder[at - 1] > noteOrder : figurePitch[at - 1] > pitch
        if !before { break }
        figurePitch[at] = figurePitch[at - 1]
        figureVelocity[at] = figureVelocity[at - 1]
        figureOrder[at] = figureOrder[at - 1]
        at -= 1
      }
      figurePitch[at] = pitch
      figureVelocity[at] = velocity
      figureOrder[at] = noteOrder
      i += 1
    }
    return count
  }

  @_noAllocation
  mutating func randomStep(_ length: Int) -> Int {
    let roll = (random.next() + 1) * 0.5
    return Int(PlayerMath.min(Double(length - 1), PlayerMath.max(0, jsFloor(roll * Double(length)))))
  }

  @_noAllocation
  mutating func advance(_ length: Int, _ mode: Int, _ opening: Bool) {
    if opening {
      started = true
      rising = mode != 1 && mode != 3
      step = rising ? 0 : length - 1
    } else if mode == 4 {
      step = randomStep(length)
    } else if mode == 1 {
      step = step - 1 < 0 ? length - 1 : step - 1
    } else if mode == 2 || mode == 3 {
      if rising {
        if step + 1 >= length {
          rising = false
          step = length > 1 ? length - 2 : 0
        } else {
          step += 1
        }
      } else if step - 1 < 0 {
        rising = true
        step = length > 1 ? 1 : 0
      } else {
        step -= 1
      }
    } else {
      // Up and Manual both walk the order already in the figure.
      step = step + 1 >= length ? 0 : step + 1
    }
  }

  @_noAllocation
  mutating func retreat(_ length: Int, _ mode: Int, _ amount: Int) {
    if length <= 1 { return }
    var moved = 0
    while moved < amount {
      if mode == 1 {
        step = step + 1 >= length ? 0 : step + 1
      } else if mode == 2 || mode == 3 {
        // Back along the same turning path, restoring the direction `advance` held there.
        if rising {
          if step - 1 < 0 {
            rising = false
            step = 1
          } else {
            step -= 1
          }
        } else if step + 1 >= length {
          rising = true
          step = length - 2
        } else {
          step += 1
        }
      } else if mode == 4 {
        step = randomStep(length)
      } else {
        step = step - 1 < 0 ? length - 1 : step - 1
      }
      moved += 1
    }
  }

  @_noAllocation
  func extreme(_ length: Int, _ high: Bool) -> Int {
    var found = 0
    var at = 1
    while at < length {
      if high ? figurePitch[at] > figurePitch[found] : figurePitch[at] < figurePitch[found] {
        found = at
      }
      at += 1
    }
    return found
  }

  @_noAllocation
  mutating func insertStep(_ length: Int, _ mode: Int, _ insert: Int, _ opening: Bool) -> Int {
    if opening {
      advance(length, mode, true)
      insertPhase = 1
      return step
    }
    if insert == 1 || insert == 2 {
      if insertPhase == 1 {
        insertPhase = 0
        return extreme(length, insert == 2)
      }
      advance(length, mode, false)
      insertPhase = 1
      return step
    }
    let forward = insert == 3 ? 3 : insert == 4 ? 4 : 0
    if forward > 0 && insertPhase >= forward {
      retreat(length, mode, insert == 3 ? 1 : 2)
      insertPhase = 1
      return step
    }
    advance(length, mode, false)
    if forward > 0 { insertPhase += 1 }
    return step
  }

  /// A collector's first lane of an inlet, which is where a performance control is read: the sum
  /// would count one control once per voice.
  @_noAllocation
  static func firstLane(_ voiceInlets: VoiceInlets?, _ inlet: Int) -> UnsafeMutablePointer<Float>? {
    guard let voiceInlets, let lanes = voiceInlets[inlet], lanes.count > 0 else { return nil }
    return lanes[0]
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    let transport = context.transport
    let pattern = context.data[0]
    let pitchIn = inlets[0]
    let gateIn = inlets[1]
    let velocityIn = inlets[2]
    let clockIn = inlets[3]
    let resetIn = inlets[4]
    let startIn = inlets[5]
    let gateCvIn = inlets[6]
    let velocityCvIn = inlets[7]
    let rateCvIn = inlets[8]
    let shiftCvIn = inlets[9]
    let voiceInlets = context.voiceInlets
    let modIn = Self.firstLane(voiceInlets, 10) ?? inlets[10]
    let bendIn = Self.firstLane(voiceInlets, 11) ?? inlets[11]
    let aftertouchIn = Self.firstLane(voiceInlets, 12) ?? inlets[12]
    let expressionIn = Self.firstLane(voiceInlets, 13) ?? inlets[13]
    let breathIn = Self.firstLane(voiceInlets, 14) ?? inlets[14]
    let sustainIn = Self.firstLane(voiceInlets, 15) ?? inlets[15]
    let pitchOut = outlets[0]
    let gateOut = outlets[1]
    let velocityOut = outlets[2]
    let trigOut = outlets[3]
    let startOut = outlets[4]
    let modOut = outlets[5]
    let bendOut = outlets[6]
    let aftertouchOut = outlets[7]
    let expressionOut = outlets[8]
    let breathOut = outlets[9]
    let sustainOut = outlets[10]
    let gateVelocityOut = outlets[11]
    let startPatched = context.inletConnected[5]
    let sustainPatched = context.outletConnected[10]
    if !startPatched { startAllowed = true }

    let sourceParam = params[0]
    let chordParam = params[1]
    let octavesParam = params[2]
    let modeParam = params[3]
    let gateParam = params[4]
    let holdParam = params[5]
    let shiftParam = params[6]
    let velocityModeParam = params[7]
    let velocityParam = params[8]
    let timingParam = params[9]
    let divisionParam = params[10]
    let rateParam = params[11]
    let patternLengthParam = params[12]
    let insertParam = params[13]
    let singleRepeatParam = params[14]
    let shuffleParam = params[15]
    let enableParam = params[16]

    let pitchVoices = ArpLanes(lanes: voiceInlets?[0], single: pitchIn)
    let gateVoices = ArpLanes(lanes: voiceInlets?[1], single: gateIn)
    let velocityVoices = ArpLanes(lanes: voiceInlets?[2], single: velocityIn)
    let widest = pitchVoices.count > gateVoices.count ? pitchVoices.count : gateVoices.count
    let inputVoices = widest < Self.voiceLimit ? widest : Self.voiceLimit

    for i in 0..<frames {
      // Performance CV passes straight through, whatever the figure is doing.
      modOut[i] = modIn[i]
      bendOut[i] = bendIn[i]
      aftertouchOut[i] = aftertouchIn[i]
      expressionOut[i] = expressionIn[i]
      breathOut[i] = breathIn[i]
      let velocityCv = Double(velocityCvIn[i])
      let sustainGate = sustainIn[i] >= 0.5
      let sustainVelocity =
        (velocityModeParam[i] >= 0.5 ? Double(velocityParam[i]) : 100.0 / 127) + velocityCv
      sustainOut[i] = sustainGate ? Float(PlayerMath.max(0, PlayerMath.min(1, sustainVelocity))) : 0
      let played = sourceParam[i] >= 0.5
      // Sustain is normalled to Hold until its outlet is patched.
      let hold = holdParam[i] >= 0.5 || (!sustainPatched && sustainGate)
      if !played && playedWas {
        activeCount = 0
        gateWas.update(repeating: 0, count: Self.voiceLimit)
        clearLatch()
      }
      playedWas = played
      let previousActive = activeCount
      var active = 0
      var clearedForChord = false

      if played {
        for voice in 0..<inputVoices {
          let gate = (gateVoices.at(voice).map { $0[i] } ?? 0) >= 0.5
          if gate { active += 1 }
          if gate && gateWas[voice] == 0 {
            if hold && previousActive == 0 && !clearedForChord {
              clearLatch()
              clearedForChord = true
            }
            orderClock += 1
            order[voice] = UInt32(truncatingIfNeeded: Int64(orderClock))
            latched[voice] = 1
          }
          gateWas[voice] = gate ? 1 : 0
          if gate {
            latchedPitch[voice] = pitchVoices.at(voice).map { $0[i] } ?? 0
            let velocity = velocityVoices.at(voice).map { Double($0[i]) } ?? 1
            latchedVelocity[voice] = Float(velocity > 0 ? PlayerMath.min(1, velocity) : 1)
          }
        }
        activeCount = active
        if !hold && active == 0 {
          started = false
          patternStarted = false
          tied = false
          gateLeft = 0
          trigLeft = 0
        }
      }

      let reset = resetIn[i] >= 0.5 ? 1 : 0
      let clock = clockIn[i] >= 0.5 ? 1 : 0
      let gateFraction = PlayerMath.max(0, PlayerMath.min(1, Double(gateParam[i]) + Double(gateCvIn[i])))
      let start = startIn[i] >= 0.5 ? 1 : 0
      let startEdge = startPatched && start == 1 && lastStart == 0
      lastStart = start
      if startEdge {
        startAllowed = true
        internalLeft = 0
        tempoPosition = 0
        tempoDelay = 0
        started = false
        patternStep = 0
        patternStarted = false
        insertPhase = 0
        singlePitchWas = .nan
        tied = false
        gateLeft = 0
        trigLeft = 0
        startGateLeft = 0
        startGateTied = false
      }
      let enabled = enableParam[i] >= 0.5
      if !enabled {
        if enableWas {
          started = false
          patternStarted = false
          tied = false
          gateLeft = 0
          trigLeft = 0
          startGateLeft = 0
          startGateTied = false
          bypassGateWas = 0
          bypassVoice = -1
        }
        enableWas = false

        // Off: a converter, following the newest held note in Played.
        var selected = -1
        if played {
          var newest: UInt32 = 0
          for voice in 0..<inputVoices where gateWas[voice] == 1 && (selected < 0 || order[voice] > newest) {
            selected = voice
            newest = order[voice]
          }
          if selected >= 0 {
            bypassPitch = pitchVoices.at(selected).map { Double($0[i]) } ?? bypassPitch
            let inputVelocity = velocityVoices.at(selected).map { Double($0[i]) } ?? 1
            let baseVelocity = velocityModeParam[i] >= 0.5 ? Double(velocityParam[i]) : inputVelocity
            bypassVelocity = PlayerMath.max(0, PlayerMath.min(1, baseVelocity + velocityCv))
          }
        } else {
          selected = gateIn[i] >= 0.5 ? 0 : -1
          bypassPitch = Double(pitchIn[i])
          let baseVelocity = velocityModeParam[i] >= 0.5 ? Double(velocityParam[i]) : Double(velocityIn[i])
          bypassVelocity = PlayerMath.max(0, PlayerMath.min(1, baseVelocity + velocityCv))
        }

        let bypassGate = selected >= 0 ? 1 : 0
        if bypassGate == 1 && (bypassGateWas == 0 || selected != bypassVoice) {
          trigLeft = trigSamples
        }
        bypassGateWas = bypassGate
        bypassVoice = selected
        pitchOut[i] = Float(bypassPitch)
        gateOut[i] = Float(bypassGate)
        velocityOut[i] = Float(bypassVelocity)
        gateVelocityOut[i] = Float(Double(bypassGate) * bypassVelocity)
        if trigLeft > 0 {
          trigLeft -= 1
          trigOut[i] = 1
        } else {
          trigOut[i] = 0
        }
        startOut[i] = 0
        lastClock = clock
        lastReset = reset
        continue
      }

      if !enableWas {
        internalLeft = 0
        tempoPosition = 0
        tempoDelay = 0
        started = false
        patternStarted = false
        insertPhase = 0
        bypassGateWas = 0
        bypassVoice = -1
      }
      enableWas = true
      if startPatched && !startAllowed {
        // Armed: silent until Start rises.
        tied = false
        gateLeft = 0
        trigLeft = 0
        startGateLeft = 0
        startGateTied = false
        lastClock = clock
        lastReset = reset
        pitchOut[i] = Float(held)
        gateOut[i] = 0
        velocityOut[i] = Float(heldVelocity)
        gateVelocityOut[i] = 0
        trigOut[i] = 0
        startOut[i] = 0
        continue
      }
      if reset == 1 && lastReset == 0 {
        started = false
        tied = false
        patternStep = 0
        patternStarted = false
      }
      lastReset = reset

      since += 1
      if tied && gateFraction < 1 { tied = false }
      let timing = Int(PlayerMath.max(0, PlayerMath.min(2, jsRound(Double(timingParam[i])))))
      if timing != timingWas {
        internalLeft = 0
        tempoPosition = 0
        tempoDelay = 0
        started = false
        patternStarted = false
        tied = false
        timingWas = timing
      }
      let insert = Int(PlayerMath.max(0, PlayerMath.min(4, jsRound(Double(insertParam[i])))))
      if insert != insertWas {
        started = false
        insertPhase = 0
        insertWas = insert
      }
      var clockEdge = timing == 0 && clock == 1 && lastClock == 0
      if timing != 0 {
        if internalLeft <= 0 {
          clockEdge = true
          var freeRate = Double(rateParam[i])
          let rateOctaves = Double(rateCvIn[i])
          if rateOctaves != 0 { freeRate *= exp2(rateOctaves) }
          internalLeft = internalInterval(
            timing, Double(divisionParam[i]), freeRate, shuffleParam[i] >= 0.5, transport)
        }
        internalLeft -= 1
      }
      if clockEdge {
        var mode = Int(jsRound(Double(modeParam[i])))
        if mode < 0 { mode = 0 } else if mode > 5 { mode = 5 }
        var octaves = Int(jsRound(Double(octavesParam[i])))
        if octaves < 1 { octaves = 1 } else if octaves > 4 { octaves = 4 }

        var base = 0
        if played {
          base = collectPlayed(pitchVoices, velocityVoices, inputVoices, i, hold, mode == 5)
        } else {
          var which = Int(jsRound(Double(chordParam[i])))
          if which < 0 { which = 0 } else if which >= 8 { which = 7 }
          let notes = Self.chordLength(which)
          for note in 0..<notes {
            figurePitch[note] = Float(Double(pitchIn[i]) + Double(Self.chordNote(which, note)) / 12)
            let inputVelocity = Double(velocityIn[i])
            figureVelocity[note] = Float(inputVelocity > 0 ? PlayerMath.min(1, inputVelocity) : 1)
          }
          base = notes
        }

        let length = Swift.min(Self.figureLimit, base * octaves)
        if base > 0 && length > 0 {
          var octave = 1
          while octave < octaves {
            var note = 0
            while note < base && octave * base + note < length {
              let at = octave * base + note
              figurePitch[at] = Float(Double(figurePitch[note]) + Double(octave))
              figureVelocity[at] = figureVelocity[note]
              figureOrder[at] = figureOrder[note]
              note += 1
            }
            octave += 1
          }

          if length != 1 { singlePitchWas = .nan }

          interval = since
          since = 0
          let patternLength = Int(
            PlayerMath.max(1, PlayerMath.min(16, jsRound(Double(patternLengthParam[i])))))
          patternStep = patternStarted ? (patternStep + 1) % patternLength : 0
          patternStarted = true
          if patternEnabled(patternStep, pattern) {
            let repeatSingle = singleRepeatParam[i] >= 0.5
            let singleChanged =
              length == 1
              && (!singlePitchWas.isFinite || abs(Double(figurePitch[0]) - singlePitchWas) >= 1e-5)
            // A chord that lost notes restarts rather than index past the figure.
            let opening = !started || step < 0 || step >= length || singleChanged
            if length == 1 && !repeatSingle && !opening {
              gateLeft = 0
              trigLeft = 0
            } else {
              let playStep = insertStep(length, mode, insert, opening)
              var figureStart = opening
              if opening {
                cycleStep = step
                cycleRising = rising
                cycleInsertPhase = insertPhase
                randomCycle = 0
              } else if mode == 4 {
                randomCycle = (randomCycle + 1) % length
                figureStart = randomCycle == 0
              } else {
                figureStart = step == cycleStep && rising == cycleRising && insertPhase == cycleInsertPhase
              }
              let shift = PlayerMath.max(
                -3, PlayerMath.min(3, jsRound(Double(shiftParam[i]) + Double(shiftCvIn[i]))))
              held = Double(figurePitch[playStep]) + shift
              let baseVelocity =
                velocityModeParam[i] >= 0.5 ? Double(velocityParam[i]) : Double(figureVelocity[playStep])
              heldVelocity = PlayerMath.max(0, PlayerMath.min(1, baseVelocity + velocityCv))
              let fraction = gateFraction
              let span = opening ? trigSamples : interval
              tied = fraction >= 1
              gateLeft = fraction > 0 && !tied ? PlayerMath.max(1, jsRound(span * fraction)) : 0
              trigLeft = trigSamples
              if figureStart {
                // Start Out is a gate the opening note's length, counted apart so later notes
                // cannot stretch it.
                startGateLeft = gateLeft
                startGateTied = tied
              }
              singlePitchWas = length == 1 ? Double(figurePitch[0]) : .nan
            }
          } else {
            // A rest: the rhythm moves on, the figure does not.
            gateLeft = 0
            tied = false
            trigLeft = 0
          }
        } else {
          started = false
          patternStarted = false
          singlePitchWas = .nan
          tied = false
          gateLeft = 0
          trigLeft = 0
        }
      }
      lastClock = clock

      pitchOut[i] = Float(held)
      velocityOut[i] = Float(heldVelocity)
      if tied && started {
        gateOut[i] = 1
      } else if gateLeft > 0 {
        gateLeft -= 1
        gateOut[i] = 1
      } else {
        gateOut[i] = 0
      }
      // Read back from the buffers, as the reference does.
      gateVelocityOut[i] = Float(Double(gateOut[i]) * Double(velocityOut[i]))
      if trigLeft > 0 {
        trigLeft -= 1
        trigOut[i] = 1
      } else {
        trigOut[i] = 0
      }
      if startGateTied && (!tied || !started) { startGateTied = false }
      if startGateTied {
        startOut[i] = 1
      } else if startGateLeft > 0 {
        startGateLeft -= 1
        startOut[i] = 1
      } else {
        startOut[i] = 0
      }
    }
  }
}
