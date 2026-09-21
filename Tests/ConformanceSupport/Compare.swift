import DriftboxDocument

/// Walks two JSON values together and says where they part. Numbers are compared as doubles,
/// exactly. Object keys are compared in order unless `ignoringKeyOrder`: a plan is built in one
/// order everywhere, but the reference writes a voice's sources as object literals whose key order
/// differs from one builder to the next, and that order means nothing.
public func collectDifferences(
  between actual: JSONValue, and expected: JSONValue, at path: String, ignoringKeyOrder: Bool = false,
  into out: inout [String]
) {
  switch (actual, expected) {
  case (.object(let a), .object(let b)):
    var mine = a.members
    var theirs = b.members
    if ignoringKeyOrder {
      mine.sort { $0.key < $1.key }
      theirs.sort { $0.key < $1.key }
    }
    if mine.map(\.key) != theirs.map(\.key) {
      out.append("\(path): keys \(mine.map(\.key)) != \(theirs.map(\.key))")
      return
    }
    for (x, y) in zip(mine, theirs) {
      collectDifferences(
        between: x.value, and: y.value, at: "\(path).\(x.key)", ignoringKeyOrder: ignoringKeyOrder, into: &out
      )
    }
  case (.array(let a), .array(let b)):
    if a.count != b.count {
      out.append("\(path): \(a.count) elements != \(b.count)")
      return
    }
    for (index, pair) in zip(a, b).enumerated() {
      collectDifferences(
        between: pair.0, and: pair.1, at: "\(path)[\(index)]", ignoringKeyOrder: ignoringKeyOrder, into: &out)
    }
  default:
    if actual != expected { out.append("\(path): \(actual.text) != \(expected.text)") }
  }
}
