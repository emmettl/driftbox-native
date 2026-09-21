/// A `ParamTimeline` of at most four events and no approaches to a target, as plain bytes: no
/// array behind it, so it can be read on the render thread and sent through a ring.
///
/// Every envelope a drum voice has fits: an amplitude is a set, two ramps and a cut-off; a pitch
/// is a set and a ramp; a choke is two sets and a ramp. It gives the same value `ParamTimeline`
/// gives for the same events — the same arithmetic in the same order — which is what lets the
/// real-time voices be checked against the offline ones to the bit.
public struct FixedTimeline {
  public static let capacity = 4

  public enum Kind: UInt8 {
    case set, linearRamp, exponentialRamp
  }

  public struct Event {
    var kind: Kind
    var value: Double
    var time: Double
  }

  public var defaultValue: Double
  var count = 0
  // Four events inline. A generic fixed array would do, except that a generic type cannot be
  // touched from a function that promises not to allocate, and `InlineArray` needs a newer system
  // than this package's floor.
  var e0 = Event(kind: .set, value: 0, time: 0)
  var e1 = Event(kind: .set, value: 0, time: 0)
  var e2 = Event(kind: .set, value: 0, time: 0)
  var e3 = Event(kind: .set, value: 0, time: 0)

  @_noAllocation
  func event(_ index: Int) -> Event {
    switch index {
    case 0: e0
    case 1: e1
    case 2: e2
    default: e3
    }
  }

  @_noAllocation
  mutating func store(_ event: Event, at index: Int) {
    switch index {
    case 0: e0 = event
    case 1: e1 = event
    case 2: e2 = event
    default: e3 = event
    }
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
    guard count < Self.capacity else { return }
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
    let span = event.time - previousTime
    switch event.kind {
    case .linearRamp:
      return span > 0 ? value + (event.value - value) * ((time - previousTime) / span) : value
    case .exponentialRamp:
      if span <= 0 || value == 0 || event.value == 0 || (value < 0) != (event.value < 0) { return value }
      return value * dbPow(event.value / value, (time - previousTime) / span)
    case .set:
      return value
    }
  }
}

/// Where a read position falls in a loop of `count` samples.
@_noAllocation
public func wrapPosition(_ position: Double, _ count: Double) -> Double {
  position >= count ? position - count * Double(Int(position / count)) : position
}
