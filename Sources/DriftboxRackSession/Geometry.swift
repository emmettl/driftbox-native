#if os(Android)
  /// The part of CoreGraphics' geometry the rack uses: a point, and a rectangle and whether a point
  /// is in it. CoreGraphics' own on Apple's platforms, and the old Foundation's on Windows and
  /// Linux; on Android the old Foundation's are not linked, so the rack has these of its own, which
  /// shadow them wherever it is imported.
  public struct CGPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  public struct CGRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// As CoreGraphics has it: its left and top edges in, its right and bottom out.
    public func contains(_ point: CGPoint) -> Bool {
      point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
  }
#endif
