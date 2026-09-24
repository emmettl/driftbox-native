import DriftboxGPU
import DriftboxText
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// A colour as a canvas takes it: red, green, blue, 0...1, and straight alpha.
public struct Colour: Hashable, Sendable {
  public var red: Float
  public var green: Float
  public var blue: Float
  public var alpha: Float

  public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// As the web writes one: `Colour(0xee3d24)` is `#ee3d24`.
  public init(_ hex: UInt32, alpha: Float = 1) {
    self.init(
      red: Float((hex >> 16) & 0xff) / 255, green: Float((hex >> 8) & 0xff) / 255,
      blue: Float(hex & 0xff) / 255, alpha: alpha)
  }

  var vector: SIMD4<Float> { SIMD4(red, green, blue, alpha) }
}

/// A canvas's transform, as Canvas2D keeps it: `x' = a x + c y + e`, `y' = b x + d y + f`.
public struct Affine: Hashable, Sendable {
  public var a: Float = 1
  public var b: Float = 0
  public var c: Float = 0
  public var d: Float = 1
  public var e: Float = 0
  public var f: Float = 0

  public init() {}

  public func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(a * point.x + c * point.y + e, b * point.x + d * point.y + f)
  }

  /// A direction rather than a point: turned and scaled, not moved.
  public func turn(_ vector: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(a * vector.x + c * vector.y, b * vector.x + d * vector.y)
  }

  /// Nothing but a move, which is what lets a glyph be drawn on the pixel grid.
  var movesOnly: Bool { a == 1 && b == 0 && c == 0 && d == 1 }
}

/// A 2D canvas drawn on the GPU layer: the part of Canvas2D that Driftbox draws with, the same on
/// every platform, where only the type comes from the platform. Graphic Lab prints its sheets on
/// one, and the interface will draw on one.
///
/// It keeps Canvas2D's state and its `save` and `restore`: a transform, a clip, a fill and a stroke,
/// a line width, a blend, a font and an alignment. Coordinates are the canvas's, x to the right and
/// y down from the top left, in pixels of the page.
///
/// Every mark is an instanced quad of one program. Marks are recorded as they are made and drawn
/// in runs, a run for each change of blend, when the page is finished or when a copy of it is
/// drawn onto itself. That copy is why there are two targets: the page is drawn so far into one,
/// then carries on in the other, which begins with the first copied into it.
public final class Canvas {
  public enum Blend: Sendable {
    /// Straight alpha over what is there: Canvas2D's `source-over`.
    case normal
    /// What is there, darkened by what is drawn: Canvas2D's `multiply`, over an opaque page.
    case multiply
  }

  public enum Align: Sendable {
    case left
    case right
    case center
  }

  struct State {
    var transform = Affine()
    var clip = SIMD4<Float>(-1e6, -1e6, 1e6, 1e6)
    var fill = Colour(0x000000)
    var stroke = Colour(0x000000)
    var lineWidth: Float = 1
    var blend = Blend.normal
    var font = FontRequest(families: ["Arial"], weight: 400, size: 10)
    var align = Align.left
  }

  /// One quad, as `canvas.vert` reads it.
  struct Mark {
    var axes: SIMD4<Float>
    var origin: SIMD4<Float>
    var colour: SIMD4<Float>
    var texture: SIMD4<Float>
    var clip: SIMD4<Float>
  }

  enum Kind: Float {
    case rectangle = 0
    case ellipse = 1
    case glyph = 2
    case image = 3
  }

  public let device: any GPUDevice
  public let typesetter: any Typesetter
  public private(set) var width = 0
  public private(set) var height = 0

  private var state = State()
  private var saved: [State] = []
  private var marks: [Mark] = []
  /// Where each run of marks under one blend starts.
  private var runs: [(start: Int, blend: Blend)] = []
  private var targets: [any GPUTarget] = []
  private var current = 0
  /// Whether the current target has been drawn into since the page began or was carried over.
  private var begun = false
  /// What an image mark shows: the page as it was before it moved to the current target.
  private var snapshot: (any GPUTexture)?
  private let blank: any GPUTexture
  private let atlas: GlyphAtlas
  private let normalPipeline: any GPUPipeline
  private let multiplyPipeline: any GPUPipeline
  /// A buffer per run, kept from page to page: the layer draws a buffer's instances from the first,
  /// so each run drawn in one pass needs its own.
  private var buffers: [any GPUBuffer] = []
  /// The lines set on this page and on the last, by their text and font. A line kept is one the
  /// page before used: a line no page has asked for since goes, so a clock that changes every
  /// frame keeps two lines here and not every one it has shown.
  private var lines: (thisPage: [LineKey: TextLine], lastPage: [LineKey: TextLine]) = ([:], [:])

  private struct LineKey: Hashable {
    var text: String
    var font: FontRequest
  }

  public init(device: any GPUDevice, typesetter: any Typesetter) throws {
    self.device = device
    self.typesetter = typesetter
    atlas = try GlyphAtlas(device: device)
    blank = try [UInt8](repeating: 0, count: 4).withUnsafeBytes {
      try device.makeTexture(width: 1, height: 1, pixels: $0)
    }
    let layout = GPUVertexLayout(
      stride: MemoryLayout<Mark>.stride, perInstance: true,
      attributes: (0..<5).map { GPUVertexLayout.Attribute(location: $0, format: .float4, offset: $0 * 16) })
    normalPipeline = try device.makePipeline(
      GPUPipelineDescriptor(program: .canvas, blend: .normal, vertexBuffers: [layout]))
    multiplyPipeline = try device.makePipeline(
      GPUPipelineDescriptor(program: .canvas, blend: .multiply, vertexBuffers: [layout]))
  }

  // MARK: - The page

  /// Start a page `width` by `height` pixels, transparent, with the state reset as Canvas2D resets
  /// it when a canvas is sized.
  public func begin(width: Int, height: Int) throws {
    if width != self.width || height != self.height || targets.isEmpty {
      targets = try (0..<2).map { _ in try device.makeTarget(width: max(1, width), height: max(1, height)) }
      self.width = width
      self.height = height
    }
    state = State()
    saved.removeAll(keepingCapacity: true)
    marks.removeAll(keepingCapacity: true)
    runs.removeAll(keepingCapacity: true)
    lines = (thisPage: [:], lastPage: lines.thisPage)
    current = 0
    begun = false
    snapshot = nil
  }

  /// Everything drawn, and the target it is in, to sample or read back.
  public func finish() -> any GPUTarget {
    flush()
    return targets[current]
  }

  // MARK: - State

  public var fill: Colour {
    get { state.fill }
    set { state.fill = newValue }
  }
  public var stroke: Colour {
    get { state.stroke }
    set { state.stroke = newValue }
  }
  public var lineWidth: Float {
    get { state.lineWidth }
    set { state.lineWidth = newValue }
  }
  public var blend: Blend {
    get { state.blend }
    set { state.blend = newValue }
  }
  public var font: FontRequest {
    get { state.font }
    set { state.font = newValue }
  }
  public var align: Align {
    get { state.align }
    set { state.align = newValue }
  }
  public var transform: Affine {
    get { state.transform }
    set { state.transform = newValue }
  }

  public func save() { saved.append(state) }

  public func restore() {
    if let top = saved.popLast() { state = top }
  }

  public func translate(_ x: Float, _ y: Float) {
    state.transform.e += state.transform.a * x + state.transform.c * y
    state.transform.f += state.transform.b * x + state.transform.d * y
  }

  public func scale(_ x: Float, _ y: Float) {
    state.transform.a *= x
    state.transform.b *= x
    state.transform.c *= y
    state.transform.d *= y
  }

  /// Clockwise on the page, which has y down, by `angle` radians.
  public func rotate(_ angle: Float) {
    let (sine, cosine) = (sin(angle), cos(angle))
    let t = state.transform
    state.transform.a = t.a * cosine + t.c * sine
    state.transform.b = t.b * cosine + t.d * sine
    state.transform.c = t.c * cosine - t.a * sine
    state.transform.d = t.d * cosine - t.b * sine
  }

  /// Narrow the clip to a rectangle, in the current transform's coordinates. The clip is kept on
  /// the page as a rectangle, so under a transform that turns it this clips to what it covers.
  public func clip(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
    let corners = [
      state.transform.apply(SIMD2(x, y)), state.transform.apply(SIMD2(x + width, y)),
      state.transform.apply(SIMD2(x, y + height)), state.transform.apply(SIMD2(x + width, y + height)),
    ]
    let low = corners.dropFirst().reduce(corners[0]) { pointwiseMin($0, $1) }
    let high = corners.dropFirst().reduce(corners[0]) { pointwiseMax($0, $1) }
    state.clip = SIMD4(
      max(state.clip.x, low.x), max(state.clip.y, low.y), min(state.clip.z, high.x), min(state.clip.w, high.y)
    )
  }

  // MARK: - Shapes

  public func fillRect(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
    place(.rectangle, x, y, width, height, colour: state.fill)
  }

  /// The ellipse that fills the rectangle.
  public func fillEllipse(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
    place(.ellipse, x, y, width, height, colour: state.fill)
  }

  /// Straight lines, each stroked `lineWidth` across and cut off flat where it ends, as Canvas2D's
  /// default `butt` caps are. Each line is its own mark, so where two lines of a translucent stroke
  /// cross, the crossing is drawn twice; Canvas2D strokes a path as one shape, and draws it once.
  public func strokeLines(_ segments: [(SIMD2<Float>, SIMD2<Float>)]) {
    for (from, to) in segments {
      let along = to - from
      let length = (along * along).sum().squareRoot()
      guard length > 0 else { continue }
      let across = SIMD2(-along.y, along.x) / length * state.lineWidth
      let corner = from - across / 2
      add(
        Mark(
          axes: Self.axes(state.transform.turn(along), state.transform.turn(across)),
          origin: Self.origin(state.transform.apply(corner), Kind.rectangle.rawValue, 0),
          colour: state.stroke.vector, texture: .zero, clip: state.clip))
    }
  }

  private func place(_ kind: Kind, _ x: Float, _ y: Float, _ width: Float, _ height: Float, colour: Colour) {
    add(
      Mark(
        axes: Self.axes(state.transform.turn(SIMD2(width, 0)), state.transform.turn(SIMD2(0, height))),
        origin: Self.origin(state.transform.apply(SIMD2(x, y)), kind.rawValue, 0),
        colour: colour.vector, texture: .zero, clip: state.clip))
  }

  /// A mark's two axes, as `aAxes` takes them.
  private static func axes(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> SIMD4<Float> {
    SIMD4(lowHalf: x, highHalf: y)
  }

  /// A mark's corner and its kind, as `aOrigin` takes them.
  private static func origin(_ corner: SIMD2<Float>, _ kind: Float, _ unused: Float) -> SIMD4<Float> {
    SIMD4(corner.x, corner.y, kind, unused)
  }

  private func add(_ mark: Mark) {
    if runs.last?.blend != state.blend { runs.append((marks.count, state.blend)) }
    marks.append(mark)
  }

  // MARK: - Type

  /// `measureText(text).width` in the current font.
  public func measure(_ text: String) -> Float {
    line(text).width
  }

  /// `text` set in the current font: from the lines this page or the last has set, or set now. A
  /// page is mostly the same text as the one before, and setting a line is a platform's shaper
  /// every time — on a phone, tens of microseconds a line even when it has seen the text before.
  private func line(_ text: String) -> TextLine {
    let key = LineKey(text: text, font: state.font)
    if let line = lines.thisPage[key] { return line }
    let line = lines.lastPage[key] ?? typesetter.line(text, font: state.font)
    lines.thisPage[key] = line
    return line
  }

  /// `fillText`: `text` on the alphabetic baseline at `y`, starting, ending or centred at `x` as
  /// the alignment says, in the current font and fill.
  public func fillText(_ text: String, _ x: Float, _ y: Float) {
    let line = line(text)
    let start =
      switch state.align {
      case .left: x
      case .right: x - line.width
      case .center: x - line.width / 2
      }
    for placed in line.glyphs {
      let pen = SIMD2(start, y) + placed.origin
      if state.transform.movesOnly {
        // On the pixel grid: the bitmap for the quarter pixel the pen is at, laid down pixel for
        // pixel, which is as sharp as the typesetter drew it.
        let at = state.transform.apply(pen)
        let whole = at.x.rounded(.down)
        var quarter = Int(((at.x - whole) * 4).rounded())
        var column = whole
        if quarter == 4 {
          quarter = 0
          column += 1
        }
        guard let entry = entry(for: placed.glyph, quarter: quarter) else { continue }
        let left = column + Float(entry.left)
        let top = at.y.rounded() + Float(entry.top)
        add(
          Mark(
            axes: SIMD4(Float(entry.width), 0, 0, Float(entry.height)),
            origin: SIMD4(left, top, Kind.glyph.rawValue, 0), colour: state.fill.vector,
            texture: entry.uv, clip: state.clip))
      } else {
        // Turned or scaled: the glyph as drawn on the grid, carried through the transform.
        guard let entry = entry(for: placed.glyph, quarter: 0) else { continue }
        let corner = pen + SIMD2(Float(entry.left), Float(entry.top))
        add(
          Mark(
            axes: Self.axes(
              state.transform.turn(SIMD2(Float(entry.width), 0)),
              state.transform.turn(SIMD2(0, Float(entry.height)))),
            origin: Self.origin(state.transform.apply(corner), Kind.glyph.rawValue, 0),
            colour: state.fill.vector, texture: entry.uv, clip: state.clip))
      }
    }
  }

  /// A glyph's place in the atlas, drawing what is recorded and starting the atlas again when a new
  /// glyph will not fit beside the ones those marks use.
  private func entry(for glyph: Glyph, quarter: Int) -> GlyphAtlas.Entry? {
    switch atlas.find(glyph, quarter: quarter, typesetter: typesetter) {
    case .entry(let entry): return entry
    case .nothing: return nil
    case .full:
      flush()
      atlas.clear()
      if case .entry(let entry) = atlas.find(glyph, quarter: quarter, typesetter: typesetter) { return entry }
      return nil
    }
  }

  // MARK: - The page onto itself

  /// The page as it is now, drawn onto itself moved by `offset` in the current transform, under the
  /// current clip: Canvas2D's `drawImage(canvas, ...)` of a canvas onto itself. What it reads is the
  /// page before this, so a run of them each read what the one before left.
  public func drawPage(shiftedBy offset: SIMD2<Float>) {
    flush()
    snapshot = targets[current].colour
    current = 1 - current
    begun = false
    let whole = SIMD4<Float>(0, 0, Float(width), Float(height))
    // The page so far, into the target it carries on in.
    marks.append(
      Mark(
        axes: SIMD4(Float(width), 0, 0, Float(height)), origin: SIMD4(0, 0, Kind.image.rawValue, 0),
        colour: SIMD4(1, 1, 1, 1), texture: SIMD4(0, 0, 1, 1), clip: whole))
    runs.append((0, .normal))
    // And the page again, moved.
    add(
      Mark(
        axes: Self.axes(
          state.transform.turn(SIMD2(Float(width), 0)), state.transform.turn(SIMD2(0, Float(height)))),
        origin: Self.origin(state.transform.apply(offset), Kind.image.rawValue, 0), colour: SIMD4(1, 1, 1, 1),
        texture: SIMD4(0, 0, 1, 1), clip: state.clip))
  }

  // MARK: - Drawing

  /// Everything recorded, drawn into the current target, in runs.
  private func flush() {
    guard !marks.isEmpty || !begun else { return }
    atlas.upload()
    // Each run's marks into a buffer of its own.
    var drawn: [(buffer: any GPUBuffer, count: Int, blend: Blend)] = []
    for (index, run) in runs.enumerated() {
      let end = index + 1 < runs.count ? runs[index + 1].start : marks.count
      guard end > run.start else { continue }
      let slice = marks[run.start..<end]
      let bytes = slice.count * MemoryLayout<Mark>.stride
      if index >= buffers.count || buffers[index].length < bytes {
        let capacity = max(bytes, 4096 * MemoryLayout<Mark>.stride)
        let made = try? [UInt8](repeating: 0, count: capacity).withUnsafeBytes {
          try device.makeBuffer($0, kind: .vertex)
        }
        guard let made else { continue }
        if index < buffers.count { buffers[index] = made } else { buffers.append(made) }
      }
      try? Array(slice).withUnsafeBytes { try buffers[index].update($0) }
      drawn.append((buffers[index], slice.count, run.blend))
    }

    var uniforms = CanvasUniforms()
    uniforms.uPage = SIMD2(Float(width), Float(height))
    let clear: GPUClear = begun ? .none : .colour(.zero)
    device.render(into: targets[current], clear: clear) { pass in
      for run in drawn {
        pass.setPipeline(run.blend == .normal ? normalPipeline : multiplyPipeline)
        uniforms.uMultiply = run.blend == .multiply ? 1 : 0
        pass.setUniforms(uniforms, binding: 0)
        pass.setVertexBuffer(run.buffer, slot: 0)
        pass.setTexture(atlas.texture, binding: 1)
        pass.setTexture(snapshot ?? blank, binding: 2)
        pass.draw(vertexCount: 6, instanceCount: run.count)
      }
    }
    begun = true
    marks.removeAll(keepingCapacity: true)
    runs.removeAll(keepingCapacity: true)
  }
}
