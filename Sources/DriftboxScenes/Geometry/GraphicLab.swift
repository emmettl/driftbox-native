#if canImport(Metal)
  import CoreGraphics
  import CoreText
  import Foundation
  import Metal
  import simd

  /// Graphic Lab: three kinds of flat music graphic sharing one printing press.
  ///
  /// This deliberately does not construct a place. The canvas only carries one screen-sized
  /// texture; every mark inside it is made in two dimensions, like a sleeve, a flyer or a
  /// broadcast frame. The three systems are an exploration rather than three half-scenes: leave
  /// it alone and it changes edition every ten seconds, or drag across the screen to move
  /// directly between A, B and C.
  ///
  /// It is the only scene here whose picture is not made by a shader. The web draws it with the
  /// Canvas2D API into an offscreen canvas and hands the result to WebGL as a texture, so the
  /// port draws it with CoreGraphics into a bitmap context and hands the result to Metal the same
  /// way. Everything below the `Sheet` is that bitmap; everything above it is one textured quad.
  public final class GraphicLab: GeometryScene {
    override public class var id: String { "graphic" }
    override public class var name: String { "Graphic Lab" }
    override public class var accent: SIMD3<Float> { SIMD3(1, 1, 1) }
    /// Never seen. Every edition's first act is to flood the whole sheet with its own paper, and
    /// the sheet covers the frame — so this is only what the clear has to be.
    override public class var background: SIMD3<Float> { .zero }

    static let bandCount = 16
    static let editionSeconds: Double = 10
    /// The sheet is printed at screen size up to this, and no further. Past it the type is
    /// already finer than anyone reads and the grain is a few hundred thousand rectangles.
    static let maxTextureEdge: CGFloat = 1280
    /// Three sheets in rotation rather than one. The bitmap is copied up by the CPU immediately
    /// before the frame that samples it is encoded, and the frame before that may still be on the
    /// GPU reading the same texture — with one texture a drag that changes edition would tear
    /// across two of them. Three is about what the drawable pool keeps in flight.
    static let inFlight = 3

    /// What one printed frame knows about the music. The web's own `Frame`.
    struct Frame {
      var width: CGFloat
      var height: CGFloat
      var time: CGFloat
      var bass: CGFloat
      var high: CGFloat
      var bands: [CGFloat]
      var title: String
      var section: String
      var bpm: Int
      var bar: Int
      var step: Int
    }

    var sheet: Sheet?
    var sheets: [MTLTexture] = []
    var slot = 0
    var printed: MTLTexture?
    var mesh: (positions: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, count: Int)!
    var pipelineState: MTLRenderPipelineState!
    /// The size of what is being drawn into, which a frame's input does not carry.
    var pixels = SIMD2<Int>(2, 2)
    /// When the scene arrived, on the renderer's clock.
    var startedAt: Double?
    var elapsed: Double = 0
    var bass: Float = 0
    var high: Float = 0
    var smoothBands = [Float](repeating: 0, count: GraphicLab.bandCount)

    override public func build() throws {
      let plane = Plane.build(width: 2, height: 2)
      mesh = (buffer(plane.positions), buffer(plane.uvs), buffer(plane.indices), plane.indices.count)
      pipelineState = try pipeline(
        vertex: "graphicLabVertex", fragment: "graphicLabFragment", blend: .none)
    }

    override public func draw(
      _ input: SceneInput, into target: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer
    ) {
      pixels = size
      super.draw(input, into: target, size: size, commandBuffer: commandBuffer)
    }

    override public func advance(_ input: SceneInput, dt: Float, aspect: Float) {
      if startedAt == nil { startedAt = input.time }
      elapsed += Double(min(dt, 0.05))
      let (rawBass, rawHigh) = input.wideLevels
      bass = Analyser.ease(bass, toward: rawBass, dt: dt, fall: 4.2)
      high = Analyser.ease(high, toward: rawHigh, dt: dt, fall: 6.5)
      for index in 0..<Self.bandCount {
        let raw = index < input.bands.count ? input.bands[index] : 0
        smoothBands[index] = Analyser.ease(smoothBands[index], toward: raw, dt: dt, fall: 5.2)
      }

      resize(for: input.pixelRatio)
      guard let sheet else { return }

      // Wall time chooses the edition. The clock the rest of the scene runs on is the sum of
      // clamped frame deltas, which stalls with the renderer; coming back from a stall should
      // reveal the next poster rather than freeze the sequence where the painting stopped.
      let seconds = input.time - (startedAt ?? input.time)
      let automatic = Int((seconds / Self.editionSeconds).rounded(.down)) % 3
      let held = input.touch != nil || touchEnergy > 0.18
      let across = min(0.999, max(0, Double(touchAt.x)))
      let edition = held ? min(2, Int((across * 3).rounded(.down))) : automatic

      let visualStep = Int((elapsed * (input.bpm / 60) * 4).rounded(.down))
      let frame = Frame(
        width: CGFloat(sheet.width), height: CGFloat(sheet.height), time: CGFloat(elapsed),
        bass: CGFloat(bass), high: CGFloat(high), bands: smoothBands.map { CGFloat($0) },
        title: "DRIFTBOX", section: ["TYPE PRESS", "XEROX NIGHT", "LIVE SIGNAL"][edition],
        bpm: Int(input.bpm.rounded()), bar: visualStep / 16, step: visualStep % 16)
      sheet.print(frame, edition: edition)
      upload(sheet)
    }

    /// The sheet is sized in points and not in pixels, because everything on it is typography:
    /// the web reads the element's CSS size for exactly this reason, so that the margins and the
    /// type stay the same fraction of the page whatever the display's density is.
    private func resize(for pixelRatio: Float) {
      let ratio = CGFloat(max(1, pixelRatio))
      let pointsWide = CGFloat(pixels.x) / ratio
      let pointsHigh = CGFloat(pixels.y) / ratio
      let scale = min(1, Self.maxTextureEdge / max(pointsWide, pointsHigh))
      let width = max(2, Int((pointsWide * scale).rounded()))
      let height = max(2, Int((pointsHigh * scale).rounded()))
      guard sheet?.width != width || sheet?.height != height else { return }
      sheet = Sheet(width: width, height: height)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = .shaderRead
      descriptor.storageMode = .shared
      sheets = (0..<Self.inFlight).compactMap { _ in device.makeTexture(descriptor: descriptor) }
      printed = nil
      slot = 0
    }

    /// CoreGraphics may move the bitmap out from under itself when a snapshot of it is still
    /// alive — which is how the broadcast edition's slips work — so where the pixels are is
    /// asked again every frame rather than kept.
    private func upload(_ sheet: Sheet) {
      guard !sheets.isEmpty, let data = sheet.context.data else { return }
      slot = (slot + 1) % sheets.count
      let texture = sheets[slot]
      texture.replace(
        region: MTLRegionMake2D(0, 0, sheet.width, sheet.height), mipmapLevel: 0, withBytes: data,
        bytesPerRow: sheet.context.bytesPerRow)
      printed = texture
    }

    override public func encode(_ encoder: MTLRenderCommandEncoder) {
      guard let printed else { return }
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBuffer(mesh.positions, offset: 0, index: 0)
      encoder.setVertexBuffer(mesh.uvs, offset: 0, index: 1)
      encoder.setFragmentTexture(printed, index: 0)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices,
        indexBufferOffset: 0)
    }

    /// A colour as the web writes it, and as the bitmap stores it: no conversion anywhere between
    /// the two, so `#ee3d24` lands in the texture as `ee 3d 24`.
    struct Colour {
      var red: CGFloat
      var green: CGFloat
      var blue: CGFloat
      var alpha: CGFloat

      init(_ hex: UInt32, _ alpha: CGFloat = 1) {
        red = CGFloat((hex >> 16) & 0xff) / 255
        green = CGFloat((hex >> 8) & 0xff) / 255
        blue = CGFloat(hex & 0xff) / 255
        self.alpha = alpha
      }
    }

    /// The web's arbitrary sequence, so the grain and the signal slips land where they land
    /// there rather than merely somewhere.
    static func hash(_ value: CGFloat) -> CGFloat {
      abs(sin(value * 91.733 + 17.17) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }

    /// `String(n).padStart(2, '0')`.
    static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// The printing press: a CoreGraphics bitmap plus the Canvas2D state the web's drawing leans
    /// on implicitly. Canvas keeps the current font and the current alignment on the context and
    /// every `fillText` reads them; CoreGraphics has no equivalent, so they are kept here — which
    /// is what lets the three editions below read the way the web's do.
    final class Sheet {
      enum Family { case display, text }
      enum Align { case left, right }

      let context: CGContext
      let width: Int
      let height: Int
      var align = Align.left
      private var font: CTFont
      private var fonts: [FontKey: CTFont] = [:]
      private var saved: [(font: CTFont, align: Align)] = []

      struct FontKey: Hashable {
        var display: Bool
        var size: Int
      }

      init?(width: Int, height: Int) {
        // Little-endian BGRA with the alpha first, which is `MTLPixelFormat.bgra8Unorm` byte for
        // byte, so the upload is a copy and nothing is swizzled on the way. The buffer is
        // CoreGraphics's own rather than ours: it is the owner that gets to copy the bitmap aside
        // when a snapshot of it is still being read.
        let info =
          CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
        guard
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else { return nil }
        self.context = context
        self.width = width
        self.height = height
        font = Sheet.resolve(.display, size: 16)
        // Grey coverage, as a browser rasterises into a canvas. Subpixel smoothing would put
        // colour fringes on every letter, and this sheet is about to be magnified onto a quad.
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSmoothing(false)
        context.setShouldAntialias(true)
      }

      /// The web's per-frame reset — `setTransform`, `globalAlpha`, the composite mode, the
      /// baseline and the alignment — and the flip that puts the rest of this file into canvas
      /// coordinates: origin at the top left, y downward.
      func begin() {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // Glyphs are laid out in text space, which the flip above would otherwise stand on its
        // head. This is the one piece of state CoreGraphics does not keep in the graphics state,
        // so it is set per frame rather than per save.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.interpolationQuality = .default
        align = .left
        saved.removeAll(keepingCapacity: true)
      }

      /// Unwinds whatever the edition left on the stack as well, so the reset above is a reset
      /// and not a hope.
      func end() {
        while saved.popLast() != nil { context.restoreGState() }
        context.restoreGState()
      }

      func save() {
        saved.append((font, align))
        context.saveGState()
      }

      func restore() {
        context.restoreGState()
        if let top = saved.popLast() {
          font = top.font
          align = top.align
        }
      }

      /// The web's two font stacks, resolved as faces rather than as families. CSS answers a
      /// weight above 500 with the nearest face at or above it, and each stack has exactly one
      /// face that far up — Arial Black for the display type, Helvetica Neue Bold for everything
      /// else — so the web's 600 and its 700 are already the same ink.
      private static func stack(_ family: Family) -> [String] {
        switch family {
        case .display: return ["Arial-Black", "HelveticaNeue-Bold", "Helvetica-Bold"]
        case .text: return ["HelveticaNeue-Bold", "Arial-BoldMT", "Helvetica-Bold"]
        }
      }

      private static func resolve(_ family: Family, size: CGFloat) -> CTFont {
        for name in stack(family) {
          let font = CTFontCreateWithName(name as CFString, size, nil)
          // A name it does not have is answered with a substitute rather than with nothing, so
          // ask the font what it turned out to be.
          if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
        return CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
      }

      /// The web's `setFont`. The weight is carried so these calls read as the web's do; the
      /// stack above is what chooses the face.
      func setFont(_ size: CGFloat, _ weight: Int = 900, _ family: Family = .display) {
        let points = max(1, size.rounded())
        let key = FontKey(display: family == .display, size: Int(points))
        if let cached = fonts[key] {
          font = cached
          return
        }
        let made = Sheet.resolve(family, size: points)
        fonts[key] = made
        font = made
      }

      private func typeset(_ text: String) -> CTLine {
        let attributes: [CFString: Any] = [
          kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true,
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        return CTLineCreateWithAttributedString(string!)
      }

      /// `measureText(text).width`: the advance, as both APIs report it.
      func measure(_ text: String) -> CGFloat {
        CTLineGetTypographicBounds(typeset(text), nil, nil, nil)
      }

      func fill(_ colour: Colour) {
        context.setFillColor(
          red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.alpha)
      }

      func fillRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        context.fill(CGRect(x: x, y: y, width: width, height: height))
      }

      /// `fillText`, in the current font and the current fill, on the alphabetic baseline.
      func fillText(_ text: String, _ x: CGFloat, _ y: CGFloat) {
        let line = typeset(text)
        let back = align == .right ? CTLineGetTypographicBounds(line, nil, nil, nil) : 0
        context.textPosition = CGPoint(x: x - back, y: y)
        CTLineDraw(line, context)
      }

      /// Type set to a width. It is squeezed horizontally and never stretched, which is why a
      /// long title narrows rather than overrunning the margin.
      func fittedText(
        _ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat,
        _ colour: Colour
      ) {
        setFont(size)
        let measured = max(1, measure(text))
        let scale = min(1, width / measured)
        save()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: scale, y: 1)
        fill(colour)
        fillText(text, 0, 0)
        restore()
      }

      /// Letter by letter with air between, for the small capitals along the top of a sheet.
      func trackedText(_ text: String, _ x: CGFloat, _ y: CGFloat, _ tracking: CGFloat) {
        var cursor = x
        for character in text {
          let one = String(character)
          fillText(one, cursor, y)
          cursor += measure(one) + tracking
        }
      }

      func rule(
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ colour: Colour
      ) {
        fill(colour)
        fillRect(x, y, width, height)
      }

      func spectrum(
        _ bands: [CGFloat], _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
        _ colour: Colour, _ gap: CGFloat = 0.18
      ) {
        let lane = width / CGFloat(bands.count)
        fill(colour)
        for (index, band) in bands.enumerated() {
          let value = 0.06 + min(1, band * 1.55)
          let barHeight = height * value
          fillRect(x + lane * CGFloat(index), y + height - barHeight, lane * (1 - gap), barHeight)
        }
      }

      func paperGrain(_ frame: Frame, _ colour: Colour) {
        fill(colour)
        let amount = Int((frame.width * frame.height / 4200).rounded(.down))
        for index in 0..<max(0, amount) {
          let at = CGFloat(index)
          let x = GraphicLab.hash(at * 2.13) * frame.width
          let y = GraphicLab.hash(at * 5.71) * frame.height
          let size = 0.5 + GraphicLab.hash(at * 8.9) * 1.7
          fillRect(x, y, size, size)
        }
      }

      func cropMarks(_ frame: Frame, _ colour: Colour) {
        let inset = max(15, frame.width * 0.022)
        let length = max(10, frame.width * 0.018)
        context.setStrokeColor(
          red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.alpha)
        context.setLineWidth(max(1, frame.width / 900))
        context.beginPath()
        for x in [inset, frame.width - inset] {
          context.move(to: CGPoint(x: x - length, y: inset))
          context.addLine(to: CGPoint(x: x + length, y: inset))
          context.move(to: CGPoint(x: x, y: inset - length))
          context.addLine(to: CGPoint(x: x, y: inset + length))
          context.move(to: CGPoint(x: x - length, y: frame.height - inset))
          context.addLine(to: CGPoint(x: x + length, y: frame.height - inset))
          context.move(to: CGPoint(x: x, y: frame.height - inset - length))
          context.addLine(to: CGPoint(x: x, y: frame.height - inset + length))
        }
        context.strokePath()
      }

      /// The web's `drawImage(canvas, 0, y, w, band, shift, y, w, band)`: the sheet printed onto
      /// itself with one band of it moved sideways. Source and destination are the same size, so
      /// what it amounts to is the whole sheet translated and clipped to the band it lands in.
      /// Snapshotted per slip rather than once, because each one reads the sheet the one before
      /// it left — which is what makes a run of them read as a signal losing lock.
      func signalSlip(y: CGFloat, band: CGFloat, shift: CGFloat) {
        guard let image = context.makeImage() else { return }
        context.saveGState()
        context.clip(to: CGRect(x: shift, y: y, width: CGFloat(width), height: band))
        // CoreGraphics lays an image down the way the bitmap is stored, so the flip that put the
        // rest of this file into canvas coordinates comes off again for this one draw.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
          image, in: CGRect(x: shift, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.restoreGState()
      }

      /// A title broken into two lines, by words where there are words and down the middle where
      /// there are not.
      func titleLines(_ title: String) -> (String, String) {
        let words = title.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 {
          let middle = (words.count + 1) / 2
          return (words[0..<middle].joined(separator: " "), words[middle...].joined(separator: " "))
        }
        let letters = Array(title)
        let middle = (letters.count + 1) / 2
        return (String(letters[0..<middle]), String(letters[middle...]))
      }

      func print(_ frame: Frame, edition: Int) {
        begin()
        if edition == 0 {
          press(frame)
        } else if edition == 1 {
          flyer(frame)
        } else {
          broadcast(frame)
        }
        end()
      }

      /// A / TYPE PRESS. Strict grid, two physical inks, the spectrum used as a rule rather than
      /// as a picture of itself.
      func press(_ frame: Frame) {
        let w = frame.width
        let h = frame.height
        let paper = Colour(0xee_e9dc)
        let blue = Colour(0x17_49d2)
        let red = Colour(0xee_3d24)
        let ink = Colour(0x14_130f)
        let margin = w * 0.055
        let pulse = frame.bass * h * 0.022
        let portrait = w < h * 0.72

        fill(paper)
        fillRect(0, 0, w, h)
        rule(0, 0, w, h * 0.105, blue)
        rule(margin, h * 0.145, w - margin * 2, max(2, h * 0.007), ink)

        fill(paper)
        setFont(h * 0.022, 700, .text)
        trackedText(
          portrait ? "DBX / EDITION A" : "DRIFTBOX / TYPE PRESS / EDITION A", margin, h * 0.068,
          w * 0.003)
        align = .right
        let count = "\(GraphicLab.pad(frame.bar + 1)) : \(GraphicLab.pad(frame.step + 1))"
        fillText(count, w - margin, h * 0.068)
        align = .left

        // Two physical inks, slightly out of register when the top end gets busy.
        let register = 2 + frame.high * 10
        save()
        context.clip(to: CGRect(x: 0, y: h * 0.15, width: w, height: h * 0.48))
        if portrait {
          let lines = titleLines(frame.title.uppercased())
          for (index, line) in [lines.0, lines.1].enumerated() {
            let baseline = h * (0.36 + CGFloat(index) * 0.215)
            fittedText(line, margin + register, baseline + pulse, w * 0.89, h * 0.215, red)
            fittedText(line, margin - register, baseline - pulse, w * 0.89, h * 0.215, blue)
            context.setBlendMode(.multiply)
            fittedText(line, margin, baseline, w * 0.89, h * 0.215, ink)
            context.setBlendMode(.normal)
          }
        } else {
          let title = frame.title.uppercased()
          fittedText(title, margin + register, h * 0.43 + pulse, w * 0.91, h * 0.29, red)
          fittedText(title, margin - register, h * 0.405 - pulse, w * 0.91, h * 0.29, blue)
          context.setBlendMode(.multiply)
          fittedText(title, margin, h * 0.418, w * 0.91, h * 0.29, ink)
        }
        restore()

        let sectionY = h * (portrait ? 0.63 : 0.605)
        rule(0, sectionY, w, h * 0.095, ink)
        // The tempo first, because the section name gets whatever width it leaves. Sized from the
        // page's height alone, the name ran straight into it on anything taller than it was wide
        // — on the web as here, until emmettl/driftbox#302.
        let tempo = "\(frame.bpm) BPM / STEREO"
        fill(paper)
        setFont(h * 0.023, 700, .text)
        let tempoWidth = measure(tempo)
        align = .right
        fillText(tempo, w - margin, sectionY + h * 0.058)
        align = .left
        fittedText(
          frame.section.uppercased(), margin, sectionY + h * 0.066, w - margin * 2.6 - tempoWidth, h * 0.055,
          paper)

        spectrum(frame.bands, margin, h * 0.745, w - margin * 2, h * 0.15, blue, 0.3)
        rule(margin, h * 0.925, w * 0.18, h * 0.012, red)
        rule(margin + w * 0.19, h * 0.925, w * 0.71, h * 0.012, ink)

        fill(ink)
        setFont(h * 0.016, 600, .text)
        let left = portrait ? "A / TYPE PRESS" : "A / STRICT TYPE, OVERPRINT, SPECTRUM AS RULE"
        fillText(left, margin, h * 0.975)
        align = .right
        fillText(portrait ? "A · B · C" : "DRAG HORIZONTAL → A · B · C", w - margin, h * 0.975)
        align = .left

        cropMarks(frame, Colour(0x14_130f, 0.65))
        paperGrain(frame, Colour(0x14_130f, 0.08))
      }

      /// B / XEROX NIGHT. Halftone, two inks off the same plate, a label repeated until it stops
      /// being information and becomes texture.
      func flyer(_ frame: Frame) {
        let w = frame.width
        let h = frame.height
        let black = Colour(0x11_100e)
        let cream = Colour(0xf1_e8cc)
        let yellow = Colour(0xf4_df1d)
        let pink = Colour(0xff_3d91)
        let margin = w * 0.045
        let kick = frame.bass * h * 0.035
        let portrait = w < h * 0.72

        fill(yellow)
        fillRect(0, 0, w, h)

        // A halftone field: frequency lanes run left to right, high energy makes the dots swell
        // until neighbouring dots print into each other.
        let spacing = max(13, (w / 70).rounded())
        fill(black)
        var y = -spacing
        while y < h + spacing {
          var x = -spacing
          while x < w + spacing {
            let lane = min(
              GraphicLab.bandCount - 1, Int((x / w * CGFloat(GraphicLab.bandCount)).rounded(.down)))
            let energy = frame.bands[max(0, lane)]
            let wave = 0.5 + 0.5 * sin(x * 0.025 + y * 0.018 - frame.time * 3)
            let radius = spacing * (0.07 + energy * 0.25 + wave * 0.08)
            context.addEllipse(
              in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fillPath()
            x += spacing
          }
          y += spacing
        }

        save()
        context.translateBy(x: w * 0.5, y: h * (portrait ? 0.31 : 0.29))
        context.rotate(by: -0.045 + frame.high * 0.018)
        rule(
          -w * 0.58, -h * (portrait ? 0.23 : 0.17), w * 1.16, h * (portrait ? 0.46 : 0.34), cream)
        if portrait {
          let lines = titleLines(frame.title.uppercased())
          for (index, line) in [lines.0, lines.1].enumerated() {
            let baseline = h * (-0.015 + CGFloat(index) * 0.19)
            fittedText(line, -w * 0.48 + frame.high * 8, baseline + kick, w * 0.96, h * 0.18, pink)
            context.setBlendMode(.multiply)
            fittedText(line, -w * 0.48 - frame.high * 8, baseline - kick, w * 0.96, h * 0.18, black)
            context.setBlendMode(.normal)
          }
        } else {
          let title = frame.title.uppercased()
          fittedText(
            title, -w * 0.48 + frame.high * 8, h * 0.09 + kick, w * 0.96, h * 0.235, pink)
          context.setBlendMode(.multiply)
          fittedText(
            title, -w * 0.48 - frame.high * 8, h * 0.075 - kick, w * 0.96, h * 0.235, black)
        }
        restore()

        save()
        context.translateBy(x: w * 0.12, y: h * 0.6)
        context.rotate(by: 0.025)
        rule(0, 0, w * 0.76, h * 0.115, black)
        // Kept on its slab: at a size taken from the height, in portrait the name ran off it.
        fittedText(frame.section.uppercased(), w * 0.025, h * 0.082, w * 0.71, h * 0.07, cream)
        restore()

        // Photocopied repetition — the label becomes texture before it becomes information.
        save()
        context.clip(to: CGRect(x: 0, y: h * 0.7, width: w, height: h * 0.22))
        setFont(h * 0.047)
        for row in 0..<6 {
          let slip = sin(frame.time * 2.1 + CGFloat(row) * 1.7) * frame.high * w * 0.045
          fill(row % 2 == 1 ? black : pink)
          fillText(
            "DRIFTBOX \(frame.bpm) BPM DRIFTBOX \(frame.bpm) BPM", -w * 0.08 + slip,
            h * (0.735 + CGFloat(row) * 0.045))
        }
        restore()

        rule(margin, h * 0.93, w - margin * 2, h * 0.045, black)
        fill(yellow)
        setFont(h * 0.018, 700, .text)
        let bar = "B / XEROX NIGHT / BAR \(GraphicLab.pad(frame.bar + 1))"
        fillText(portrait ? "B / XEROX" : bar, margin * 1.35, h * 0.96)
        align = .right
        fillText(portrait ? "DOT / TEAR" : "INK / DOT / REPEAT / TEAR", w - margin * 1.35, h * 0.96)
        align = .left

        cropMarks(frame, black)
        paperGrain(frame, Colour(0x11_100e, 0.16))
      }

      /// C / LIVE SIGNAL. A station identity: safe-area grid, a monogram filling the frame, a
      /// timecode, and the picture occasionally losing its lock.
      func broadcast(_ frame: Frame) {
        let w = frame.width
        let h = frame.height
        let blue = Colour(0x0b_32ad)
        let white = Colour(0xf5_f3e9)
        let orange = Colour(0xff_4c1f)
        let black = Colour(0x0b_0b11)
        let margin = w * 0.045
        // Narrow as the other two editions measure it, which this one alone never did.
        let portrait = w < h * 0.72
        let phase = (frame.time * 0.12).truncatingRemainder(dividingBy: 1)

        fill(blue)
        fillRect(0, 0, w, h)

        context.setStrokeColor(red: 245 / 255, green: 243 / 255, blue: 233 / 255, alpha: 0.18)
        context.setLineWidth(1)
        var x: CGFloat = 0
        while x <= w {
          context.beginPath()
          context.move(to: CGPoint(x: x, y: 0))
          context.addLine(to: CGPoint(x: x, y: h))
          context.strokePath()
          x += w / 12
        }
        var y: CGFloat = 0
        while y <= h {
          context.beginPath()
          context.move(to: CGPoint(x: 0, y: y))
          context.addLine(to: CGPoint(x: w, y: y))
          context.strokePath()
          y += h / 8
        }

        rule(0, h * 0.055, w * (0.2 + phase * 0.8), h * 0.035, orange)
        rule(w * (0.84 - phase * 0.4), h * 0.105, w * 0.5, h * 0.012, white)

        fill(white)
        setFont(h * 0.024, 700, .text)
        trackedText("DBX / LIVE SIGNAL", margin, h * 0.165, w * 0.0025)
        align = .right
        fillText("CH \(GraphicLab.pad(frame.bar % 12 + 1))", w - margin, h * 0.165)
        align = .left

        let initials = frame.title.split(whereSeparator: { $0.isWhitespace })
          .compactMap { $0.first }
        let monogram = String(initials.prefix(3))
        save()
        context.clip(to: CGRect(x: 0, y: h * 0.18, width: w, height: h * 0.49))
        let jump = frame.bass * h * 0.03
        fittedText(
          (monogram.isEmpty ? "DBX" : monogram).uppercased(), margin, h * 0.61 + jump, w * 0.92,
          h * 0.54, white)

        // Signal slips are hard horizontal copies, not a soft digital "glitch" effect.
        for slice in 0..<5 {
          let at = CGFloat(slice)
          let top = h * (0.25 + GraphicLab.hash(at * 8.3) * 0.34)
          let band = h * (0.012 + GraphicLab.hash(at * 3.1) * 0.025)
          let seed = at * 7.7 + (frame.time * 8).rounded(.down)
          let shift = (GraphicLab.hash(seed) - 0.5) * frame.high * w * 0.24
          signalSlip(y: top, band: band, shift: shift)
        }
        restore()

        rule(0, h * 0.68, w, h * 0.12, orange)
        fittedText(frame.section.uppercased(), margin, h * 0.765, w - margin * 2, h * 0.074, black)

        let seconds = Int(frame.time.rounded(.down))
        let timecode =
          "\(GraphicLab.pad(seconds / 60)):\(GraphicLab.pad(seconds % 60))"
          + ":\(GraphicLab.pad(frame.bar + 1)):\(GraphicLab.pad(frame.step + 1))"
        fill(white)
        setFont(h * 0.044, 700, .text)
        fillText(timecode, margin, h * 0.88)
        align = .right
        fillText("\(frame.bpm).00", w - margin, h * 0.88)
        align = .left

        spectrum(frame.bands, margin, h * 0.91, w - margin * 2, h * 0.045, white, 0.45)
        fill(white)
        setFont(h * 0.015, 700, .text)
        // Shortened in portrait, as the other two editions' footers already were.
        fillText(
          portrait ? "C / BROADCAST" : "C / BROADCAST ID / AUDIO-LOCKED TRANSMISSION", margin, h * 0.985)
        align = .right
        fillText(portrait ? "A · B · C" : "DRAG HORIZONTAL → A · B · C", w - margin, h * 0.985)
        align = .left
      }
    }

    static let source = """

      struct GraphicLabVarying {
        float4 position [[position]];
        float2 vUv;
      };

      vertex GraphicLabVarying graphicLabVertex(
        uint vid [[vertex_id]], constant float3 *positions [[buffer(0)]],
        constant float2 *uvs [[buffer(1)]]
      ) {
        GraphicLabVarying out;
        out.vUv = uvs[vid];
        // No camera and no model: the plane is two units square about the origin, so its own xy
        // IS clip space. The scene is a sheet of paper held against the glass.
        out.position = float4(positions[vid].xy, 0.0, 1.0);
        return out;
      }

      fragment float4 graphicLabFragment(
        GraphicLabVarying in [[stage_in]], texture2d<float> graphic [[texture(0)]]
      ) {
        constexpr sampler ink(filter::linear, mip_filter::none, address::clamp_to_edge);
        // The plane's v runs up the screen and the bitmap's first row is its top, which is the
        // flip three performs on the way into a canvas texture and this performs on the way out.
        // The sheet is opaque — every edition floods it before it draws — so what comes back is
        // colour and nothing else.
        return graphic.sample(ink, float2(in.vUv.x, 1.0 - in.vUv.y));
      }

      """
  }
#endif
