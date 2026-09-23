/// A `ParamTimeline` of at most six events and no approaches to a target, as plain bytes: no
/// array behind it, so it can be read on the render thread and sent through a ring.
///
/// Every envelope a drum voice has fits: an amplitude is a set, two ramps and a cut-off; a pitch
/// is a set and a ramp; a choke is two sets and a ramp. It gives the same value `ParamTimeline`
/// gives for the same events — the same arithmetic in the same order — which is what lets the
/// real-time voices be checked against the offline ones to the bit.
public struct FixedTimeline {
  public static var capacity: Int { 6 }

  public enum Kind: UInt8 {
    case set, linearRamp, exponentialRamp
  }

  public struct Event {
    var kind: Kind
    var value: Double
    var time: Double
    /// See `ParamTimeline.Event.heading`.
    var hasHeading = false
    var headingValue = 0.0
    var headingTime = 0.0
  }

  public var defaultValue: Double
  var count = 0
  // Four events inline. A generic fixed array would do, except that a generic type cannot be
  // touched from a function that promises not to allocate.
  var e0 = Event(kind: .set, value: 0, time: 0)
  var e1 = Event(kind: .set, value: 0, time: 0)
  var e2 = Event(kind: .set, value: 0, time: 0)
  var e3 = Event(kind: .set, value: 0, time: 0)
  var e4 = Event(kind: .set, value: 0, time: 0)
  var e5 = Event(kind: .set, value: 0, time: 0)

  @_noAllocation
  func event(_ index: Int) -> Event {
    switch index {
    case 0: e0
    case 1: e1
    case 2: e2
    case 3: e3
    case 4: e4
    default: e5
    }
  }

  @_noAllocation
  mutating func store(_ event: Event, at index: Int) {
    switch index {
    case 0: e0 = event
    case 1: e1 = event
    case 2: e2 = event
    case 3: e3 = event
    case 4: e4 = event
    default: e5 = event
    }
  }

  /// Forget everything from the start. Between notes on one parameter this is what a fresh
  /// timeline would be, but keeps whatever the caller wants to carry over as `defaultValue`.
  @_noAllocation
  public mutating func removeAll() {
    count = 0
  }

  /// `ParamTimeline.cancel(from:lastRendered:)`, the same way: a ramp under way is kept up to
  /// `lastRendered` and the parameter then snaps back to where the ramp started.
  @_noAllocation
  public mutating func cancel(from time: Double, lastRendered: Double?) {
    // Nothing before an event that has already played will be read again — a cancellation
    // promises that no frame before `lastRendered` is still to come — so it can go, and the room
    // is needed for what comes next.
    if let lastRendered {
      while count >= 2, event(1).time <= lastRendered {
        for index in 1..<count { store(event(index), at: index - 1) }
        count -= 1
      }
    }
    var first = 0
    while first < count, event(first).time < time { first += 1 }
    guard first < count else { return }
    var playedRamp: Event?
    var snap: Event?
    if let lastRendered, lastRendered < event(first).time {
      let before = first > 0 ? event(first - 1) : Event(kind: .set, value: defaultValue, time: 0)
      switch event(first).kind {
      case .linearRamp, .exponentialRamp:
        if lastRendered > before.time {
          var cut = event(first)
          cut.hasHeading = true
          cut.headingValue = cut.value
          cut.headingTime = cut.time
          cut.value = value(at: lastRendered)
          cut.time = lastRendered
          playedRamp = cut
          snap = Event(kind: .set, value: before.value, time: lastRendered.nextUp)
        }
      case .set:
        break
      }
    }
    count = first
    if let playedRamp, count < 6 {
      store(playedRamp, at: count)
      count += 1
    }
    if let snap { append(snap.kind, value: snap.value, at: snap.time) }
  }

  public init(defaultValue: Double) {
    self.defaultValue = defaultValue
  }

  /// Nil if the timeline has more events than fit, or any approach to a target.
  public init?(_ timeline: ParamTimeline) {
    guard timeline.events.count <= Self.capacity, !timeline.hasTargets else { return nil }
    defaultValue = timeline.defaultValue
    for event in timeline.events {
      let kind: Kind
      switch event.kind {
      case .set: kind = .set
      case .linearRamp: kind = .linearRamp
      case .exponentialRamp: kind = .exponentialRamp
      case .target: return nil
      }
      store(Event(kind: kind, value: event.value, time: event.time), at: count)
      count += 1
    }
  }

  public var hasRoom: Bool { count < Self.capacity }

  /// Add an event later than every event so far. Ignored if there is no room.
  @_noAllocation
  public mutating func append(_ kind: Kind, value: Double, at time: Double) {
    guard count < 6 else { return }
    store(Event(kind: kind, value: value, time: time), at: count)
    count += 1
  }

  @_noAllocation
  public func value(at time: Double) -> Double {
    var low = 0
    while low < count, event(low).time <= time { low += 1 }
    let value = low > 0 ? event(low - 1).value : defaultValue
    guard low < count else { return value }
    let previousTime = low > 0 ? event(low - 1).time : 0
    let event = event(low)
    let endValue = event.hasHeading ? event.headingValue : event.value
    let endTime = event.hasHeading ? event.headingTime : event.time
    let span = endTime - previousTime
    switch event.kind {
    case .linearRamp:
      return span > 0 ? value + (endValue - value) * ((time - previousTime) / span) : value
    case .exponentialRamp:
      if span <= 0 || value == 0 || endValue == 0 || (value < 0) != (endValue < 0) { return value }
      return value * dbPow(endValue / value, (time - previousTime) / span)
    case .set:
      return value
    }
  }

  /// The same timeline `seconds` later: how a hit prepared against a song's own clock is placed
  /// on the engine's when the song loops round.
  @_noAllocation
  public mutating func shift(by seconds: Double) {
    for index in 0..<count {
      var moved = event(index)
      moved.time += seconds
      if moved.hasHeading { moved.headingTime += seconds }
      store(moved, at: index)
    }
  }
}

/// Where a read position falls in a loop of `count` samples.
@_noAllocation
public func wrapPosition(_ position: Double, _ count: Double) -> Double {
  position >= count ? position - count * Double(Int(position / count)) : position
}
