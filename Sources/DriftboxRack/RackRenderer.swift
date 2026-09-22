// The rack without an audio device: a patch in, float buffers out. A port of the reference's
// `RackRenderer` (`headless.ts`), which is also what the conformance fixtures are rendered with,
// so the two can be held to each other block for block.

public final class RackRenderer {
  public let sampleRate: Double
  public let frames: Int
  public private(set) var plan: Plan?
  private var graph: RackGraph?
  /// Data the host pushed, which outlives a patch change: recompiling must not throw away a
  /// sample somebody loaded. It wins over the patch's own data in the same slot.
  private var pushed: [String: [String: [Float]]] = [:]

  public init(sampleRate: Double = 48000, frames: Int = 128) {
    self.sampleRate = sampleRate
    self.frames = frames
  }

  /// Compile and build a patch. Every module restarts, as a patch edit does in the reference;
  /// the clock, the transport and the master limiter carry on, because they are the graph's.
  public var patch: Patch? {
    didSet {
      guard let patch else {
        plan = nil
        graph = nil
        return
      }
      let compiled = compile(patch)
      plan = compiled
      var fresh = RackGraph(plan: compiled, sampleRate: sampleRate, frames: frames)
      if let carried = graph?.carried { fresh.inherit(carried) }
      for (module, slots) in pushed {
        for (slot, samples) in slots { fresh.setData(module: module, slot: slot, samples: samples) }
      }
      graph = consume fresh
    }
  }

  public var notes: [PlanNote] { plan?.notes ?? [] }

  /// Turn a knob, by module and param id, on every voice or one.
  public func setParam(_ module: String, _ param: String, _ value: Double, voice: Int? = nil) {
    guard let slot = plan?.slots[module]?[param] else { return }
    graph?.setParam(slot: slot, value: value, voice: voice)
  }

  /// Turn a knob at an exact frame of the renderer's clock.
  public func scheduleParam(_ module: String, _ param: String, _ value: Double, frame: Int, voice: Int? = nil)
  {
    guard let slot = plan?.slots[module]?[param] else { return }
    graph?.setParam(slot: slot, value: value, voice: voice, frame: frame)
  }

  /// Hand a module some bulk data: a sample, a table.
  public func setData(_ module: String, _ slot: String, _ samples: [Float]) {
    pushed[module, default: [:]][slot] = samples
    graph?.setData(module: module, slot: slot, samples: samples)
  }

  public func setTransport(tempo: Double, running: Bool, shuffle: Double = 0) {
    graph?.setTransport(tempo: tempo, running: running, shuffle: shuffle)
  }

  /// One block into `left` and `right`, each `frames` long, with the host's input buses.
  public func process(
    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, host: HostInputs = .none
  ) {
    guard graph != nil else {
      left.update(repeating: 0, count: frames)
      right.update(repeating: 0, count: frames)
      return
    }
    graph!.process(left: left, right: right, host: host)
  }

  /// `count` frames, rendered whole blocks at a time and trimmed to length.
  public func render(frames count: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    let blockLeft = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let blockRight = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer {
      blockLeft.deallocate()
      blockRight.deallocate()
    }
    var done = 0
    while done < count {
      process(left: blockLeft, right: blockRight)
      let take = min(frames, count - done)
      for i in 0..<take {
        left[done + i] = blockLeft[i]
        right[done + i] = blockRight[i]
      }
      done += take
    }
    return (left, right)
  }
}

extension RackGraph {
  /// What outlives a patch change: the clock, the transport and the limiter's state.
  public struct Carried {
    var frame: Int
    var tempo: Double
    var running: Bool
    var beat: Double
    var shuffle: Double
    var limitEnvelope: Double
    var limitGain: Double
  }

  public var carried: Carried {
    @_noAllocation get {
      Carried(
        frame: frame, tempo: tempo, running: running, beat: beat, shuffle: shuffle,
        limitEnvelope: limitEnvelope,
        limitGain: limitGain)
    }
  }

  @_noAllocation
  public mutating func inherit(_ state: Carried) {
    frame = state.frame
    tempo = state.tempo
    running = state.running
    beat = state.beat
    shuffle = state.shuffle
    limitEnvelope = state.limitEnvelope
    limitGain = state.limitGain
  }
}
