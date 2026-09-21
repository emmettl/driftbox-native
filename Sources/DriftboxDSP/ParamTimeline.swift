/// A parameter that moves in time: the Web Audio `AudioParam` automation calls, evaluated per
/// sample.
///
/// The reference describes every envelope — amplitude, pitch, filter sweep — as calls on an
/// `AudioParam`, and the browser turns those into a value for each sample frame. This is that,
/// following the Web Audio specification's formulas, so a description written for one plays the
/// same on the other. Times are seconds on the same clock as the frames being rendered.
public struct ParamTimeline {
  enum Kind {
    case set
    case linearRamp
    case exponentialRamp
    /// An exponential approach with a time constant: `setTargetAtTime`.
    case target(timeConstant: Double)
  }

  struct Event {
    var kind: Kind
    var value: Double
    var time: Double
    /// For a ramp cut short by `cancel`: where and to what it was originally heading, so that the
    /// part already played is computed exactly as it was played. `time` and `value` then say
    /// where it was cut.
    var heading: (value: Double, time: Double)?
  }

  /// What the parameter holds before its first event.
  public var defaultValue: Double
  var events: [Event] = []
  /// Whether any event is an approach to a target, which is the one kind that carries history.
  var hasTargets = false

  public init(defaultValue: Double) {
    self.defaultValue = defaultValue
  }

  public var isConstant: Bool { events.isEmpty }

  public mutating func setValue(_ value: Double, at time: Double) {
    insert(Event(kind: .set, value: value, time: time))
  }

  public mutating func linearRamp(to value: Double, at time: Double) {
    insert(Event(kind: .linearRamp, value: value, time: time))
  }

  public mutating func exponentialRamp(to value: Double, at time: Double) {
    insert(Event(kind: .exponentialRamp, value: value, time: time))
  }

  public mutating func setTarget(_ value: Double, at time: Double, timeConstant: Double) {
    hasTargets = true
    insert(Event(kind: .target(timeConstant: timeConstant), value: value, time: time))
  }

  /// `cancelScheduledValues`: forget everything due at or after `time`.
  ///
  /// A ramp is due when it *ends*, so one still under way is forgotten too. What it had already
  /// done is not undone — the call is made at some moment, and the part of the ramp before that
  /// moment has been played. `lastRendered` is the time of the last frame rendered before the
  /// call: the ramp is kept up to there.
  ///
  /// And then the parameter **jumps back** to where the ramp started, because with the ramp gone
  /// the last thing the timeline knows is the event before it. It does not hold where the ramp had
  /// got to. That was measured against the browser rather than assumed: a 303's filter, its sweep
  /// cancelled by the next note, snaps back open for the frames until that note begins.
  ///
  /// With no `lastRendered` the call is taken to be made before anything has played, and a ramp
  /// under way is simply forgotten.
  public mutating func cancel(from time: Double, lastRendered: Double? = nil) {
    guard let first = events.firstIndex(where: { $0.time >= time }) else { return }
    var played: [Event] = []
    if let lastRendered, lastRendered < events[first].time {
      let before = first > 0 ? events[first - 1] : Event(kind: .set, value: defaultValue, time: 0)
      switch events[first].kind {
      case .linearRamp, .exponentialRamp:
        if lastRendered > before.time {
          // The part already played stays exactly as it was played: the ramp is cut at
          // `lastRendered` but keeps heading where it was heading, so the arithmetic for every
          // frame before the cut is unchanged.
          var cut = events[first]
          cut.heading = (cut.value, cut.time)
          cut.value = value(at: lastRendered)
          cut.time = lastRendered
          played.append(cut)
          played.append(Event(kind: .set, value: before.value, time: lastRendered.nextUp))
        }
      case .set, .target:
        break
      }
    }
    events.removeSubrange(first...)
    events.append(contentsOf: played)
  }

  /// Kept in time order; an event at the same time as another goes after it, as the
  /// specification says.
  private mutating func insert(_ event: Event) {
    let index = events.firstIndex { $0.time > event.time } ?? events.count
    events.insert(event, at: index)
  }

  /// A ramp's value at `time`, from `value` at `previousTime`. The same arithmetic in the same order
  /// as `FixedTimeline`, which is what lets a real-time form be held to an offline one to the bit.
  @inline(__always)
  static func ramp(_ event: Event, from value: Double, at previousTime: Double, to time: Double) -> Double {
    let endValue = event.heading?.value ?? event.value
    let endTime = event.heading?.time ?? event.time
    let span = endTime - previousTime
    switch event.kind {
    case .linearRamp:
      return span > 0 ? value + (endValue - value) * ((time - previousTime) / span) : value
    case .exponentialRamp:
      if span <= 0 || value == 0 || endValue == 0 || (value < 0) != (endValue < 0) { return value }
      return value * dbPow(endValue / value, (time - previousTime) / span)
    case .set, .target:
      return value
    }
  }

  /// The value at `time`.
  ///
  /// A ramp runs from the event before it — from that event's time and the value the parameter
  /// had reached there — to its own time and value, and holds afterwards.
  public func value(at time: Double) -> Double {
    // A timeline of sets and ramps is decided by the two events either side of `time`, which a
    // search finds directly. Only an approach to a target carries history, and needs the walk
    // below. A whole song's worth of 303 notes is thousands of events read millions of times, so
    // this is the difference between a render that takes seconds and one that takes minutes.
    if !hasTargets {
      var low = 0
      var high = events.count
      while low < high {
        let middle = (low + high) / 2
        if events[middle].time <= time { low = middle + 1 } else { high = middle }
      }
      let value = low > 0 ? events[low - 1].value : defaultValue
      guard low < events.count else { return value }
      let previousTime = low > 0 ? events[low - 1].time : 0
      let event = events[low]
      return Self.ramp(event, from: value, at: previousTime, to: time)
    }

    var value = defaultValue
    var previousTime = 0.0
    var index = 0
    while index < events.count {
      let event = events[index]
      let next = index + 1 < events.count ? events[index + 1] : nil

      if event.time > time {
        // Not reached yet. It only matters now if it is a ramp, which is already under way. (A
        // ramp to, from or through zero has no exponential; the specification holds the start
        // value until the ramp's end.)
        return Self.ramp(event, from: value, at: previousTime, to: time)
      }

      switch event.kind {
      case .set, .linearRamp, .exponentialRamp:
        value = event.value
      case .target(let timeConstant):
        // Runs until the next event takes over, and hands that event the value it had reached.
        let until = min(time, next?.time ?? time)
        if timeConstant > 0 {
          value = event.value + (value - event.value) * dbExp(-(until - event.time) / timeConstant)
        } else {
          value = event.value
        }
      }
      previousTime = event.time
      index += 1
    }
    return value
  }
}
