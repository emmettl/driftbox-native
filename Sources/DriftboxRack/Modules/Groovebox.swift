import DriftboxDSP

// The groovebox as a rack source: a port of `driftbox/packages/rack/src/modules/groovebox.ts`.
//
// The song's machines are rendered by the engine, not here: the host plays the retained song and
// hands the 808, the 909, 303 A and 303 B to the graph on its input buses 0 to 3, a stereo pair
// each. This only crosses that boundary — each machine through a strip of level, pan and mute onto
// a stereo outlet of its own — and meters what comes out, so that once past it the machines are
// ordinary rack audio.

/// Level, pan and mute for each of the four machines, and what each is reading.
public struct GrooveboxModule {
  /// The 808, the 909, 303 A and 303 B: the reference's `GROOVEBOX_SECTIONS`.
  public static let sections = ["tr808", "tr909", "303.a", "303.b"]

  let sampleRate: Double
  /// For each machine: the last block's squares — its level, once a reading takes their root, off
  /// the render thread — its peak, its envelope, and forty-eight waveform points.
  var squares: (Double, Double, Double, Double) = (0, 0, 0, 0)
  var blockFrames = 0
  var peaks: (Float, Float, Float, Float) = (0, 0, 0, 0)
  var envelopes: (Float, Float, Float, Float) = (0, 0, 0, 0)
  let waveforms: UnsafeMutablePointer<Float>

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    waveforms = .allocate(capacity: 4 * 48)
    waveforms.initialize(repeating: 0, count: 4 * 48)
  }

  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {
    let frames = context.frames
    for section in 0..<4 {
      let left = context.host.buffer(bus: section, channel: 0)
      let right = context.host.buffer(bus: section, channel: 1) ?? left
      let leftOut = outlets[section * 2]
      let rightOut = outlets[section * 2 + 1]
      // The three params a machine has, in the order the definition gives them.
      let level = params[section * 3]
      let pan = params[section * 3 + 1]
      let mute = params[section * 3 + 2]
      var squares = 0.0
      var peak = 0.0
      blockFrames = frames
      for i in 0..<frames {
        let balance = max(-1, min(1, Double(pan[i])))
        let gain = mute[i] >= 0.5 ? 0 : Double(level[i])
        let leftGain = balance > 0 ? 1 - balance : 1
        let rightGain = balance < 0 ? 1 + balance : 1
        var inLeft = 0.0
        var inRight = 0.0
        if let left { inLeft = Double(left[i]) }
        if let right { inRight = Double(right[i]) }
        leftOut[i] = Float(inLeft * gain * leftGain)
        rightOut[i] = Float(inRight * gain * rightGain)
        let l = Double(leftOut[i])
        let r = Double(rightOut[i])
        squares += l * l + r * r
        let samplePeak = max(abs(l), abs(r))
        if samplePeak > peak { peak = samplePeak }
      }

      let previous = Double(envelope(section))
      let release = powDSP(0.01, Double(frames) / max(1, sampleRate * 0.3))
      set(
        section, squares: squares, peak: Float(peak),
        envelope: Float(peak >= previous ? peak : peak + (previous - peak) * release))

      let waveform = waveforms + section * 48
      for point in 0..<48 {
        let index = max(0, min(frames - 1, point * frames / 48))
        let sample = frames > 0 ? (Double(leftOut[index]) + Double(rightOut[index])) * 0.5 : 0
        waveform[point] = Float(max(-1, min(1, sample)))
      }
    }
  }

  @_noAllocation
  func envelope(_ section: Int) -> Float {
    switch section {
    case 0: envelopes.0
    case 1: envelopes.1
    case 2: envelopes.2
    default: envelopes.3
    }
  }

  @_noAllocation
  mutating func set(_ section: Int, squares: Double, peak: Float, envelope: Float) {
    switch section {
    case 0:
      self.squares.0 = squares
      peaks.0 = peak
      envelopes.0 = envelope
    case 1:
      self.squares.1 = squares
      peaks.1 = peak
      envelopes.1 = envelope
    case 2:
      self.squares.2 = squares
      peaks.2 = peak
      envelopes.2 = envelope
    default:
      self.squares.3 = squares
      peaks.3 = peak
      envelopes.3 = envelope
    }
  }

  /// Machine `section`'s reading, after its strip, as the reference's `meters()` gives it.
  func reading(_ section: Int) -> MeterReading {
    let values: (Double, Float, Float) =
      switch section {
      case 0: (squares.0, peaks.0, envelopes.0)
      case 1: (squares.1, peaks.1, envelopes.1)
      case 2: (squares.2, peaks.2, envelopes.2)
      default: (squares.3, peaks.3, envelopes.3)
      }
    // Kept as the reference keeps it, in a float.
    let level = Float(blockLevel(values.0, blockFrames * 2))
    return MeterReading(
      level: Double(level), peak: Double(values.1), envelope: Double(values.2),
      waveform: Array(UnsafeBufferPointer(start: waveforms + section * 48, count: 48)))
  }

  func release() { waveforms.deallocate() }
}

extension RackModules {
  /// The machine names on the panel, and the ids its ports and params take from the machine's,
  /// as the reference's `GROOVEBOX_PORTS` makes them: `tr808-out`, `303-a-level`, and so on, with
  /// the left and right aliases of patches made before its outlets were stereo.
  static let groovebox: ModuleDef = {
    // The section with its dot made a dash, which is all `GROOVEBOX_PORTS` does to it.
    let machines = [
      ("tr808", "tr808", "808"), ("tr909", "tr909", "909"), ("303.a", "303-a", "303 A"),
      ("303.b", "303-b", "303 B"),
    ]
    var outlets: [Port] = []
    var params: [ParamDef] = []
    for (section, id, name) in machines {
      outlets.append(
        Port("\(id)-out", name, stereo: true, aliases: [("\(section)-l", 0), ("\(section)-r", 1)]))
      params.append(ParamDef("\(id)-level", "\(name) Level", min: 0, max: 1, default: 1))
      params.append(ParamDef("\(id)-pan", "\(name) Pan", min: -1, max: 1, default: 0))
      params.append(ParamDef("\(id)-mute", "\(name) Mute", min: 0, max: 1, default: 0, stepped: true))
    }
    var def = ModuleDef(type: "groovebox", name: "Groovebox", inlets: [], outlets: outlets, params: params)
    def.version = 2
    def.poly = false
    return def
  }()
}
