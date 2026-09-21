/// A string-keyed map that remembers the order its keys arrived in.
///
/// The reference keeps tracks, kit entries and the rest in JavaScript objects, which iterate in
/// insertion order, and that order is not decoration: it is the order hits are planned in, and so
/// eventually the order they are summed in. A `Dictionary` would lose it.
///
/// Lookup is a linear scan. These maps hold a machine's worth of voices — a couple of dozen at the
/// outside — and at that size a scan beats hashing a string.
public struct OrderedMap<Value> {
  public private(set) var keys: [String] = []
  public private(set) var values: [Value] = []

  public init() {}

  public var count: Int { keys.count }
  public var isEmpty: Bool { keys.isEmpty }

  public func index(of key: String) -> Int? {
    keys.firstIndex(of: key)
  }

  public subscript(key: String) -> Value? {
    get {
      guard let index = index(of: key) else { return nil }
      return values[index]
    }
    set {
      if let index = index(of: key) {
        if let newValue {
          values[index] = newValue
        } else {
          keys.remove(at: index)
          values.remove(at: index)
        }
      } else if let newValue {
        keys.append(key)
        values.append(newValue)
      }
    }
  }
}

extension OrderedMap: Equatable where Value: Equatable {}
extension OrderedMap: Sendable where Value: Sendable {}
