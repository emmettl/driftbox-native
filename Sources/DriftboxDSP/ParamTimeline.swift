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
  }

  /// What the parameter holds before its first event.
  public var defaultValue: Double
  var events: [Event] = []

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
          // A stretch of a line is a line, and of an exponential an exponential, so the part
          // already played is the same kind of ramp ending sooner.
          played.append(Event(kind: events[first].kind, value: value(at: lastRendered), time: lastRendered))
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

  /// The value at `time`.
  ///
  /// A ramp runs from the event before it — from that event's time and the value the parameter
  /// had reached there — to its own time and value, and holds afterwards.
  public func value(at time: Double) -> Double {
    var value = defaultValue
    var previousTime = 0.0
    var index = 0
    while index < events.count {
      let event = events[index]
      let next = index + 1 < events.count ? events[index + 1] : nil

      if event.time > time {
        // Not reached yet. It only matters now if it is a ramp, which is already under way.
        switch event.kind {
        case .linearRamp:
          let span = event.time - previousTime
          return span > 0 ? value + (event.value - value) * ((time - previousTime) / span) : value
        case .exponentialRamp:
          let span = event.time - previousTime
          // A ramp to, from or through zero has no exponential; the specification holds the
          // start value until the ramp's end.
          if span <= 0 || value == 0 || event.value == 0 || (value < 0) != (event.value < 0) {
            return value
          }
          return value * dbPow(event.value / value, (time - previousTime) / span)
        case .set, .target:
          return value
        }
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
