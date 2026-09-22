#if canImport(Metal)
  import Metal
  import simd

  /// Longhand. Most Driftbox scenes treat a touch as a force: material bends, turns or gathers
  /// under the finger, then returns to what it was. This one makes the opposite promise. The
  /// empty stave belongs to the player. Every drag lays a piece of luminous tubing into the
  /// scene, and lifting a finger commits it. The mark remains until the scene is left.
  ///
  /// The music does not redraw the gesture. It reads it: a small playhead travels the route,
  /// bass blooms its halo and high frequencies sharpen the ink. That distinction matters. If
  /// the track were allowed to change the shape, the drawing would stop feeling authored as
  /// soon as the finger lifted.
  ///
  /// The web declares a fog, and here — unlike the scenes built on a `ShaderMaterial`, which
  /// three leaves unfogged — it is real, because every material in this scene is one of
  /// three's own. It is still almost nothing: the fog starts ten units out, the page and all
  /// of its ink sit nine units from the camera, and only the dust is scattered deep enough to
  /// reach it. So the fog is carried by the dust alone.
  public final class Longhand: GeometryScene {
    override public class var id: String { "longhand" }
    override public class var name: String { "Longhand" }
    override public class var accent: SIMD3<Float> { SIMD3(255, 95, 145) / 255 }
    override public class var background: SIMD3<Float> { SIMD3(0x03, 0x04, 0x0a) / 255 }

    /// Marks kept before the oldest is dropped, and points kept in one mark. Both are limits
    /// on the tubing rebuilt every time the finger moves, not on how long a gesture may be.
    static let maxStrokes = 12
    static let maxPoints = 180
    /// How far the finger must travel before another point is laid. Without it a held finger
    /// stacks hundreds of coincident points and the spline through them is undefined.
    static let sampleGap: Float = 0.045
    static let coreRadius: Float = 0.025
    static let haloRadius: Float = 0.09
    /// three's own default for a tube's cross section.
    static let radialSegments = 6
    static let colours: [SIMD3<Float>] = [
      SIMD3(0xff, 0x4f, 0x87) / 255, SIMD3(0xff, 0xb3, 0x47) / 255, SIMD3(0x77, 0xf2, 0xd0) / 255,
      SIMD3(0x62, 0xb7, 0xff) / 255, SIMD3(0xd5, 0x8c, 0xff) / 255, SIMD3(0xf8, 0xf3, 0xdc) / 255,
    ]
    static let white = SIMD3<Float>(1, 1, 1)
    /// The tube is remade at `max(8, points * 2)` segments, so this is the most it ever holds.
    static let maxSegments = maxPoints * 2
    static let maxVertices = (maxSegments + 1) * (radialSegments + 1)
    static let maxIndices = maxSegments * radialSegments * 6
    /// Specks of dust across the sheet, to give the void a depth it otherwise has not got.
    static let moteCount = 120

    struct InkUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var origin = SIMD3<Float>(repeating: 0)
      var colour = SIMD3<Float>(repeating: 1)
      var radius: Float = 1
      var opacity: Float = 1
    }

    struct PageUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(repeating: 1)
    }

    struct DustUniforms {
      var projectionMatrix = matrix_identity_float4x4
      var modelViewMatrix = matrix_identity_float4x4
      var colour = SIMD3<Float>(repeating: 1)
      var fogColour = Longhand.background
      var size: Float = 1.4
      var opacity: Float = 0.2
      var fogNear: Float = 10
      var fogFar: Float = 18
    }

    /// One mark: the points the finger laid down, the curve through them, and the lattice its
    /// two tubes are drawn from. The core and the halo differ only in radius, so what is
    /// stored per vertex is the centre of the tube and the unit direction out to its skin —
    /// one lattice, scaled twice by the shader, rather than two.
    final class Stroke {
      var points: [SIMD3<Float>] = []
      var curve: Curve?
      var colour = Longhand.colours[0]
      let centres: MTLBuffer
      let directions: MTLBuffer
      let indices: MTLBuffer
      var indexCount = 0
      /// Where the nib is, and where the playhead has got to along the route.
      var tip = SIMD3<Float>(repeating: 0)
      var reader = SIMD3<Float>(repeating: 0)
      var tipScale: Float = 1
      var readerScale: Float = 1
      /// The ink's own colour, walked toward white by the top end.
      var ink = Longhand.colours[0]

      init(centres: MTLBuffer, directions: MTLBuffer, indices: MTLBuffer) {
        self.centres = centres
        self.directions = directions
        self.indices = indices
      }

      func reset(colour: SIMD3<Float>) {
        points.removeAll(keepingCapacity: true)
        curve = nil
        indexCount = 0
        self.colour = colour
        ink = colour
      }
    }

    var ink = InkUniforms()
    var page = PageUniforms()
    var dust = DustUniforms()
    var strokes: [Stroke] = []
    var spare: [Stroke] = []
    var current: Stroke?
    /// Started true, so entering Longhand does not adopt a press that began in the scene
    /// before it: the finger already down is ignored until it lifts and presses again.
    var drawing = true
    var bass: Float = 0
    var high: Float = 0
    var time: Float = 0
    /// The drawing buffer's height, which the dust is sized against.
    var pixels: Float = 900
    var grid: MTLBuffer!
    var gridCount = 0
    var motes: MTLBuffer!
    var ball: (positions: MTLBuffer, indices: MTLBuffer, count: Int)!
    var corePipeline: MTLRenderPipelineState!
    var haloPipeline: MTLRenderPipelineState!
    var tipPipeline: MTLRenderPipelineState!
    var readerPipeline: MTLRenderPipelineState!
    var gridPipeline: MTLRenderPipelineState!
    var dustPipeline: MTLRenderPipelineState!

    override public func build() throws {
      let lines = Self.sheet()
      grid = buffer(lines)
      gridCount = lines.count
      motes = buffer(Self.scatter())
      let sphere = Self.sphere()
      ball = (buffer(sphere.positions), buffer(sphere.indices), sphere.indices.count)

      // Every mark a stroke could ever need, taken once. The tubing is rewritten in place on
      // each new point, which happens at pointer rate under the finger — the one moment in
      // the scene where allocating would be felt.
      let vertexBytes = Self.maxVertices * MemoryLayout<SIMD3<Float>>.stride
      let indexBytes = Self.maxIndices * MemoryLayout<UInt32>.stride
      for _ in 0..<Self.maxStrokes {
        guard let centres = device.makeBuffer(length: vertexBytes, options: .storageModeShared),
          let directions = device.makeBuffer(length: vertexBytes, options: .storageModeShared),
          let indices = device.makeBuffer(length: indexBytes, options: .storageModeShared)
        else { continue }
        spare.append(Stroke(centres: centres, directions: directions, indices: indices))
      }

      corePipeline = try pipeline(
        vertex: "longhandTubeVertex", fragment: "longhandInkFragment", blend: .none)
      haloPipeline = try pipeline(
        vertex: "longhandTubeVertex", fragment: "longhandInkFragment", blend: .additive)
      tipPipeline = try pipeline(
        vertex: "longhandMarkVertex", fragment: "longhandInkFragment", blend: .none)
      readerPipeline = try pipeline(
        vertex: "longhandMarkVertex", fragment: "longhandInkFragment", blend: .additive)
      gridPipeline = try pipeline(
        vertex: "longhandGridVertex", fragment: "longhandGridFragment", blend: .none)
      dustPipeline = try pipeline(
        vertex: "longhandDustVertex", fragment: "longhandDustFragment", blend: .normal)
      page.colour = SIMD3(0x09, 0x13, 0x26) / 255
      dust.colour = SIMD3(0x6d, 0xa7, 0xdb) / 255
    }

    /// The web sizes its dust against the drawing buffer's height in pixels rather than
    /// against the pixel ratio, and that height is the one thing a frame's input does not
    /// carry. It is taken from the texture being drawn into instead.
    override public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
      pixels = Float(size.y)
      super.draw(input, into: target, size: size, commandBuffer: commandBuffer)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      // Square to the page and still. Nothing here moves the camera, because a drawing that
      // drifts under the hand is not a drawing you can aim.
      camera.position = SIMD3(0, 0, 9)
      camera.target = SIMD3(repeating: 0)

      // A press starts a new piece of ink and every frame of it extends that stroke. Release
      // commits it simply by ceasing to append: no decay, no timer and no hidden "settle"
      // phase — what was drawn is now part of the scene.
      if let touch = input.touch {
        if !drawing { startStroke() }
        drawing = true
        append(pointOnPage(touch, aspect: aspect))
      } else {
        current = nil
        drawing = false
      }

      let (rawBass, rawHigh) = input.wideLevels
      bass = Analyser.ease(bass, toward: rawBass, dt: dt, fall: 2.8)
      high = Analyser.ease(high, toward: rawHigh, dt: dt, fall: 5)
      if input.running { time += dt }

      let beat = time * Float(input.bpm) / 60
      for (index, stroke) in strokes.enumerated() {
        stroke.ink = simd_mix(stroke.colour, Self.white, SIMD3(repeating: high * 0.35))
        stroke.tipScale = 0.7 + high * 0.7
        guard let curve = stroke.curve else { continue }
        // One traversal every four beats. Offsetting the strokes turns several marks into a
        // score being read in canon rather than a row of identical progress indicators.
        let at = (beat / 4 + Float(index) / Float(max(1, strokes.count)))
          .truncatingRemainder(dividingBy: 1)
        stroke.reader = curve.point(atArc: at)
        stroke.readerScale = 0.7 + bass * 1.5 + high * 0.8
      }

      ink.projectionMatrix = camera.projection(aspect: aspect)
      ink.modelViewMatrix = camera.view
      page.projectionMatrix = ink.projectionMatrix
      page.modelViewMatrix = camera.view * modelMatrix(position: SIMD3(0, 0, -1.2))
      dust.projectionMatrix = ink.projectionMatrix
      dust.modelViewMatrix = ink.modelViewMatrix
      // A point's size is in drawing-buffer pixels whatever the screen, so it is scaled by the
      // height rather than left to shrink into nothing on a dense display.
      dust.size = max(1.2, pixels / 900) * (1.2 + high * 1.8)
      dust.opacity = 0.18 + high * 0.18
    }

    /// Put the finger on the plane the tubes occupy.
    ///
    /// The camera stays square to that plane, so this is the perspective projection written
    /// backwards rather than a guessed world width. It is direct in portrait as well as
    /// landscape: the centre of the fingertip and the centre of the new tube coincide.
    func pointOnPage(_ at: SIMD2<Float>, aspect: Float) -> SIMD3<Float> {
      let height = 2 * tan(camera.fovDegrees * .pi / 360) * camera.position.z
      return SIMD3((at.x - 0.5) * height * aspect, (at.y - 0.5) * height, 0)
    }

    func startStroke() {
      // The web reads the colour off the count BEFORE the new mark joins it, and the count
      // stops at twelve — so the thirteenth mark onward comes out the same pink as the first.
      let colour = Self.colours[strokes.count % Self.colours.count]
      guard let stroke = spare.popLast() ?? (strokes.isEmpty ? nil : strokes.removeFirst()) else {
        return
      }
      stroke.reset(colour: colour)
      strokes.append(stroke)
      current = stroke
    }

    func append(_ point: SIMD3<Float>) {
      guard let stroke = current, stroke.points.count < Self.maxPoints else { return }
      if let previous = stroke.points.last, simd_distance(previous, point) < Self.sampleGap {
        return
      }
      stroke.points.append(point)
      stroke.tip = point
      guard stroke.points.count > 1 else { return }
      let curve = Curve(points: stroke.points)
      stroke.curve = curve
      rebuild(stroke, along: curve)
    }

    /// three's `TubeGeometry`, rewritten in place. A tube's rings are carried by Frenet
    /// frames, and on a stroke drawn flat on the page those collapse: the frame's normal is
    /// the page's own, and its binormal is the tangent turned a quarter within the page. So a
    /// ring is a circle about the tangent, which is all this has to say.
    func rebuild(_ stroke: Stroke, along curve: Curve) {
      let segments = max(8, stroke.points.count * 2)
      let ring = Self.radialSegments
      let centres = stroke.centres.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.maxVertices)
      let directions = stroke.directions.contents().bindMemory(
        to: SIMD3<Float>.self, capacity: Self.maxVertices)
      var vertex = 0
      for segment in 0...segments {
        let u = Float(segment) / Float(segments)
        let centre = curve.point(atArc: u)
        let tangent = curve.tangent(atArc: u)
        let across = SIMD3(-tangent.y, tangent.x, 0)
        for step in 0...ring {
          let angle = Float(step) / Float(ring) * .pi * 2
          centres[vertex] = centre
          directions[vertex] = across * sin(angle) + SIMD3(0, 0, cos(angle))
          vertex += 1
        }
      }

      let indices = stroke.indices.contents().bindMemory(to: UInt32.self, capacity: Self.maxIndices)
      var index = 0
      for segment in 1...segments {
        for step in 1...ring {
          let a = UInt32((ring + 1) * (segment - 1) + step - 1)
          let b = UInt32((ring + 1) * segment + step - 1)
          let c = UInt32((ring + 1) * segment + step)
          let d = UInt32((ring + 1) * (segment - 1) + step)
          indices[index] = a
          indices[index + 1] = b
          indices[index + 2] = d
          indices[index + 3] = b
          indices[index + 4] = c
          indices[index + 5] = d
          index += 6
        }
      }
      stroke.indexCount = index
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      // three shows one side of a surface, and here that is not cosmetic: the halo is additive,
      // so drawing the far wall of the tube as well would double its glow.
      encoder.setCullMode(.back)

      // three's own order, opaque before transparent: the page, then the ink and its nibs, then
      // the dust and everything additive. Every material in the web scene has its depth writing
      // turned off but the grid's, and the grid is behind all of it — so nothing here is ever
      // hidden by anything, and this order alone decides what lands on top of what. The halo
      // going on last over its own core adds to it rather than covering it, which is the point
      // of it being additive.
      encoder.setRenderPipelineState(gridPipeline)
      encoder.setVertexBytes(&page, length: MemoryLayout<PageUniforms>.stride, index: 0)
      encoder.setVertexBuffer(grid, offset: 0, index: 1)
      encoder.setFragmentBytes(&page, length: MemoryLayout<PageUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridCount)

      encoder.setRenderPipelineState(corePipeline)
      for stroke in strokes where stroke.indexCount > 0 {
        draw(tube: stroke, colour: stroke.ink, radius: Self.coreRadius, opacity: 1, into: encoder)
      }

      encoder.setRenderPipelineState(tipPipeline)
      for stroke in strokes where !stroke.points.isEmpty {
        draw(
          mark: stroke.tip, colour: stroke.colour, radius: 0.075 * stroke.tipScale, opacity: 1,
          into: encoder)
      }

      encoder.setRenderPipelineState(dustPipeline)
      encoder.setVertexBytes(&dust, length: MemoryLayout<DustUniforms>.stride, index: 0)
      encoder.setVertexBuffer(motes, offset: 0, index: 1)
      encoder.setFragmentBytes(&dust, length: MemoryLayout<DustUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.moteCount)

      encoder.setRenderPipelineState(haloPipeline)
      let halo = 0.08 + bass * 0.2
      for stroke in strokes where stroke.indexCount > 0 {
        draw(
          tube: stroke, colour: stroke.colour, radius: Self.haloRadius, opacity: halo, into: encoder)
      }

      encoder.setRenderPipelineState(readerPipeline)
      for stroke in strokes where stroke.curve != nil {
        draw(
          mark: stroke.reader, colour: Self.white, radius: 0.075 * stroke.readerScale,
          opacity: 0.95, into: encoder)
      }
    }

    func draw(
      tube stroke: Stroke, colour: SIMD3<Float>, radius: Float, opacity: Float,
      into encoder: MTLRenderCommandEncoder
    ) {
      ink.origin = SIMD3(repeating: 0)
      ink.colour = colour
      ink.radius = radius
      ink.opacity = opacity
      encoder.setVertexBytes(&ink, length: MemoryLayout<InkUniforms>.stride, index: 0)
      encoder.setVertexBuffer(stroke.centres, offset: 0, index: 1)
      encoder.setVertexBuffer(stroke.directions, offset: 0, index: 2)
      encoder.setFragmentBytes(&ink, length: MemoryLayout<InkUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: stroke.indexCount, indexType: .uint32,
        indexBuffer: stroke.indices, indexBufferOffset: 0)
    }

    func draw(
      mark at: SIMD3<Float>, colour: SIMD3<Float>, radius: Float, opacity: Float,
      into encoder: MTLRenderCommandEncoder
    ) {
      ink.origin = at
      ink.colour = colour
      ink.radius = radius
      ink.opacity = opacity
      encoder.setVertexBytes(&ink, length: MemoryLayout<InkUniforms>.stride, index: 0)
      encoder.setVertexBuffer(ball.positions, offset: 0, index: 1)
      encoder.setFragmentBytes(&ink, length: MemoryLayout<InkUniforms>.stride, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: ball.count, indexType: .uint32, indexBuffer: ball.indices,
        indexBufferOffset: 0)
    }

    /// three's `GridHelper` at thirty squares a side, stood up into the page's plane — which
    /// is what the web's quarter turn about x amounts to. A page rather than a void, and
    /// deliberately quiet until somebody writes.
    static func sheet() -> [SIMD3<Float>] {
      let size: Float = 30
      let divisions = 30
      let half = size / 2
      let step = size / Float(divisions)
      var out: [SIMD3<Float>] = []
      for line in 0...divisions {
        let at = -half + Float(line) * step
        out += [SIMD3(-half, -at, 0), SIMD3(half, -at, 0)]
        out += [SIMD3(at, half, 0), SIMD3(at, -half, 0)]
      }
      return out
    }

    /// Deterministic rather than random at mount: returning to the scene should feel like
    /// returning to the same sheet, not loading a new backdrop.
    static func scatter() -> [SIMD3<Float>] {
      var roll = Roll(seed: 0.314159)
      return (0..<moteCount).map { _ in
        SIMD3(
          (roll.next() - 0.5) * 24, (roll.next() - 0.5) * 18, -0.6 - roll.next() * 4)
      }
    }

    /// three's `SphereGeometry` at the nib's own twelve by eight, as a unit ball: the tip and
    /// the playhead are the same lattice at different radii, so it is built once.
    static func sphere() -> (positions: [SIMD3<Float>], indices: [UInt32]) {
      let across = 12
      let down = 8
      var positions: [SIMD3<Float>] = []
      var indices: [UInt32] = []
      for iy in 0...down {
        let theta = Float(iy) / Float(down) * .pi
        for ix in 0...across {
          let phi = Float(ix) / Float(across) * .pi * 2
          positions.append(
            SIMD3(-cos(phi) * sin(theta), cos(theta), sin(phi) * sin(theta)))
        }
      }
      for iy in 0..<down {
        for ix in 0..<across {
          let a = UInt32(iy * (across + 1) + ix + 1)
          let b = UInt32(iy * (across + 1) + ix)
          let c = UInt32((iy + 1) * (across + 1) + ix)
          let d = UInt32((iy + 1) * (across + 1) + ix + 1)
          // The poles are a single point, so one of each cap's two triangles is degenerate
          // and three leaves it out.
          if iy != 0 { indices += [a, b, d] }
          if iy != down - 1 { indices += [b, c, d] }
        }
      }
      return (positions, indices)
    }

    /// three's `CatmullRomCurve3` in its centripetal form, with the arc-length table three
    /// parameterises it by. Centripetal rather than uniform because a fast flick leaves two
    /// samples far apart, and a uniform Catmull-Rom answers that by looping the spline out
    /// past them — centripetal cannot cross itself between points, which is the difference
    /// between ink and a knot.
    struct Curve {
      /// three's `arcLengthDivisions`.
      static let divisions = 200
      let points: [SIMD3<Float>]
      private var lengths: [Float]

      init(points: [SIMD3<Float>]) {
        self.points = points
        lengths = []
        lengths.reserveCapacity(Self.divisions + 1)
        lengths.append(0)
        var previous = point(at: 0)
        var total: Float = 0
        for step in 1...Self.divisions {
          let next = point(at: Float(step) / Float(Self.divisions))
          total += simd_distance(next, previous)
          lengths.append(total)
          previous = next
        }
      }

      /// The spline at `t` through the points, one span at a time — three's `getPoint`.
      func point(at t: Float) -> SIMD3<Float> {
        let count = points.count
        guard count > 1 else { return points.first ?? SIMD3(repeating: 0) }
        let scaled = Float(count - 1) * min(max(t, 0), 1)
        var index = Int(scaled.rounded(.down))
        var weight = scaled - Float(index)
        if index > count - 2 {
          index = count - 2
          weight = 1
        }
        // An open curve is missing the control point at each end, so three invents them by
        // reflecting the neighbour: the spline leaves the ends straight rather than curling.
        let p0 = index > 0 ? points[index - 1] : points[0] * 2 - points[1]
        let p1 = points[index]
        let p2 = points[index + 1]
        let p3 = index + 2 < count ? points[index + 2] : points[count - 1] * 2 - points[count - 2]
        // Centripetal: each span's knot spacing is the fourth root of its squared length, and
        // a span of no length borrows its neighbour's rather than dividing by zero.
        var dt1 = pow(simd_distance_squared(p1, p2), 0.25)
        if dt1 < 1e-4 { dt1 = 1 }
        var dt0 = pow(simd_distance_squared(p0, p1), 0.25)
        if dt0 < 1e-4 { dt0 = dt1 }
        var dt2 = pow(simd_distance_squared(p2, p3), 0.25)
        if dt2 < 1e-4 { dt2 = dt1 }
        let m1 = ((p1 - p0) / dt0 - (p2 - p0) / (dt0 + dt1) + (p2 - p1) / dt1) * dt1
        let m2 = ((p2 - p1) / dt1 - (p3 - p1) / (dt1 + dt2) + (p3 - p2) / dt2) * dt1
        let cubic = 2 * p1 - 2 * p2 + m1 + m2
        let square = -3 * p1 + 3 * p2 - 2 * m1 - m2
        return ((cubic * weight + square) * weight + m1) * weight + p1
      }

      /// Where on the spline a given fraction of its LENGTH falls — three's `getUtoTmapping`.
      /// Without it the playhead would crawl through the crowded parts of a stroke and sprint
      /// through the open ones, which reads as the drawing being uneven rather than the hand.
      func t(forArc u: Float) -> Float {
        guard let total = lengths.last, total > 0 else { return 0 }
        let target = min(max(u, 0), 1) * total
        var index = 0
        while index < lengths.count - 2 && lengths[index + 1] <= target { index += 1 }
        let span = lengths[index + 1] - lengths[index]
        let fraction = span > 0 ? (target - lengths[index]) / span : 0
        return (Float(index) + fraction) / Float(lengths.count - 1)
      }

      func point(atArc u: Float) -> SIMD3<Float> { point(at: t(forArc: u)) }

      /// three takes a curve's tangent as a difference across a tiny step rather than
      /// analytically, and the step is small enough to matter to where the rings sit.
      func tangent(atArc u: Float) -> SIMD3<Float> {
        let at = t(forArc: u)
        let delta: Float = 0.0001
        let direction = point(at: min(1, at + delta)) - point(at: max(0, at - delta))
        let length = simd_length(direction)
        return length > 0 ? direction / length : SIMD3(1, 0, 0)
      }
    }

    static let source = """

      struct LonghandInkUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uOrigin;
        float3 uColour;
        float uRadius;
        float uOpacity;
      };
      struct LonghandInkVarying {
        float4 position [[position]];
      };

      vertex LonghandInkVarying longhandTubeVertex(
        uint vid [[vertex_id]], constant LonghandInkUniforms &u [[buffer(0)]],
        constant float3 *centres [[buffer(1)]], constant float3 *directions [[buffer(2)]]
      ) {
        LonghandInkVarying out;
        // The tube's skin, at whichever of the two radii is being drawn. The core is the mark
        // and the halo is the same mark four times as thick and almost transparent, which is
        // what makes the ink look lit from inside rather than merely bright.
        float3 pos = centres[vid] + directions[vid] * u.uRadius;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      vertex LonghandInkVarying longhandMarkVertex(
        uint vid [[vertex_id]], constant LonghandInkUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        LonghandInkVarying out;
        float3 pos = u.uOrigin + vertices[vid] * u.uRadius;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(pos, 1.0);
        return out;
      }

      fragment float4 longhandInkFragment(constant LonghandInkUniforms &u [[buffer(0)]]) {
        // Unlit and flat, as three's basic material is. The ink is a light source in the
        // scene, not something the scene lights.
        return float4(u.uColour, u.uOpacity);
      }

      struct LonghandGridUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
      };
      struct LonghandGridVarying {
        float4 position [[position]];
      };

      vertex LonghandGridVarying longhandGridVertex(
        uint vid [[vertex_id]], constant LonghandGridUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        LonghandGridVarying out;
        out.position = u.projectionMatrix * u.modelViewMatrix * float4(vertices[vid], 1.0);
        return out;
      }

      fragment float4 longhandGridFragment(constant LonghandGridUniforms &u [[buffer(0)]]) {
        return float4(u.uColour, 1.0);
      }

      struct LonghandDustUniforms {
        float4x4 projectionMatrix;
        float4x4 modelViewMatrix;
        float3 uColour;
        float3 uFogColour;
        float uSize;
        float uOpacity;
        float uFogNear;
        float uFogFar;
      };
      struct LonghandDustVarying {
        float4 position [[position]];
        float pointSize [[point_size]];
        float vDepth;
      };

      vertex LonghandDustVarying longhandDustVertex(
        uint vid [[vertex_id]], constant LonghandDustUniforms &u [[buffer(0)]],
        constant float3 *vertices [[buffer(1)]]
      ) {
        LonghandDustVarying out;
        float4 view = u.modelViewMatrix * float4(vertices[vid], 1.0);
        out.position = u.projectionMatrix * view;
        // Sized in pixels and not by distance, so the specks stay specks: dust on the glass
        // rather than a starfield with a near edge.
        out.pointSize = u.uSize;
        out.vDepth = -view.z;
        return out;
      }

      fragment float4 longhandDustFragment(
        LonghandDustVarying in [[stage_in]], constant LonghandDustUniforms &u [[buffer(0)]]
      ) {
        // The scene's fog, which reaches nothing else. A square sprite a couple of pixels
        // across, as three's own point is — there is no room in it for a round mask.
        float fog = smoothstep(u.uFogNear, u.uFogFar, in.vDepth);
        return float4(mix(u.uColour, u.uFogColour, fog), u.uOpacity);
      }

      """
  }
#endif
