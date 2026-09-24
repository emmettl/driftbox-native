import DriftboxCanvas
import DriftboxGPU
import DriftboxText
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

/// Graphic Lab: three kinds of flat music graphic sharing one printing press.
///
/// This deliberately does not construct a place. The canvas only carries one screen-sized
/// texture; every mark inside it is made in two dimensions, like a sleeve, a flyer or a
/// broadcast frame. The three systems are an exploration rather than three half-scenes: leave
/// it alone and it changes edition every ten seconds, or drag across the screen to move
/// directly between A, B and C.
///
/// It is the only scene here whose picture is not made by a shader of its own. The web draws it
/// with the Canvas2D API into an offscreen canvas and hands the result to WebGL as a texture; this
/// draws it on `DriftboxCanvas`, the same part of Canvas2D on the GPU layer, with the platform's
/// type, and lays the page over the frame the same way. Everything in `Press` is that page;
/// everything outside it is one textured triangle.
public final class GraphicLabScene: GPUGeometryScene {
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
  static let maxTextureEdge: Float = 1280

  /// What one printed frame knows about the music. The web's own `Frame`.
  struct Frame {
    var width: Float
    var height: Float
    var time: Float
    /// The same clock in double precision, for the hash, which the web feeds JavaScript's doubles.
    var clock: Double
    var bass: Float
    var high: Float
    var bands: [Float]
    var title: String
    var section: String
    var bpm: Int
    var bar: Int
    var step: Int
  }

  var press: Press!
  var printed: (any GPUTarget)?
  var pipelineState: (any GPUPipeline)!
  /// When the scene arrived, on the renderer's clock.
  var startedAt: Double?
  var elapsed: Double = 0
  var bass: Float = 0
  var high: Float = 0
  var smoothBands = [Float](repeating: 0, count: GraphicLabScene.bandCount)

  override public func build() throws {
    press = Press(canvas: try Canvas(device: device, typesetter: typesetter))
    pipelineState = try pipeline(.graphicLab)
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

    // The sheet is sized in points and not in pixels, because everything on it is typography:
    // the web reads the element's CSS size for exactly this reason, so that the margins and the
    // type stay the same fraction of the page whatever the display's density is.
    let ratio = max(1, input.pixelRatio)
    let pointsWide = viewport.x / ratio
    let pointsHigh = viewport.y / ratio
    let scale = min(1, Self.maxTextureEdge / max(pointsWide, pointsHigh))
    let width = max(2, Int((pointsWide * scale).rounded()))
    let height = max(2, Int((pointsHigh * scale).rounded()))

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
      width: Float(width), height: Float(height), time: Float(elapsed), clock: elapsed, bass: bass,
      high: high,
      bands: smoothBands, title: "DRIFTBOX", section: ["TYPE PRESS", "XEROX NIGHT", "LIVE SIGNAL"][edition],
      bpm: Int(input.bpm.rounded()), bar: visualStep / 16, step: visualStep % 16)
    printed = try? press.print(frame, edition: edition)
  }

  override public func encode(_ pass: any GPUPass) {
    guard let printed else { return }
    pass.setPipeline(pipelineState)
    pass.setTexture(printed.colour, binding: 0)
    pass.draw(vertexCount: 3)
  }

  /// The web's arbitrary sequence, so the grain and the signal slips land where they land
  /// there rather than merely somewhere. In double precision, argument and all, as JavaScript's
  /// numbers are: the sine of these large arguments is not the same number in single.
  static func hash(_ value: Double) -> Float {
    Float(abs(sin(value * 91.733 + 17.17) * 43758.5453).truncatingRemainder(dividingBy: 1))
  }

  /// `String(n).padStart(2, '0')`.
  static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

extension GraphicLabScene {
  /// The printing press: a canvas, and the handful of things the web's three editions draw with
  /// that Canvas2D does not have as such — type set to a width, tracked type, rules, a spectrum,
  /// paper grain, crop marks, and a band of the sheet slipping sideways.
  final class Press {
    enum Family { case display, text }

    let canvas: Canvas

    init(canvas: Canvas) { self.canvas = canvas }

    /// The web's two font stacks. CSS answers a weight above 500 with the nearest face at or above
    /// it, and each stack has exactly one face that far up — Arial Black for the display type,
    /// Helvetica Neue Bold for everything else — so the web's 600 and its 700 are already the
    /// same ink, and only the stack decides the face.
    static func font(_ size: Float, _ family: Family) -> FontRequest {
      switch family {
      case .display:
        FontRequest(
          families: ["Arial Black", "Helvetica Neue", "Helvetica", "Arial"], weight: 900, size: size)
      case .text:
        FontRequest(families: ["Helvetica Neue", "Arial", "Helvetica"], weight: 700, size: size)
      }
    }

    /// The web's `setFont`. The weight is carried so these calls read as the web's do; the stack
    /// is what chooses the face.
    func setFont(_ size: Float, _ weight: Int = 900, _ family: Family = .display) {
      canvas.font = Self.font(max(1, size.rounded()), family)
    }

    func fill(_ colour: Colour) { canvas.fill = colour }

    func fillRect(_ x: Float, _ y: Float, _ width: Float, _ height: Float) {
      canvas.fillRect(x, y, width, height)
    }

    func fillText(_ text: String, _ x: Float, _ y: Float) { canvas.fillText(text, x, y) }

    func measure(_ text: String) -> Float { canvas.measure(text) }

    func save() { canvas.save() }

    func restore() { canvas.restore() }

    var align: Canvas.Align {
      get { canvas.align }
      set { canvas.align = newValue }
    }

    /// Type set to a width. It is squeezed horizontally and never stretched, which is why a
    /// long title narrows rather than overrunning the margin.
    func fittedText(
      _ text: String, _ x: Float, _ y: Float, _ width: Float, _ size: Float, _ colour: Colour
    ) {
      setFont(size)
      let measured = max(1, measure(text))
      let scale = min(1, width / measured)
      save()
      canvas.translate(x, y)
      canvas.scale(scale, 1)
      fill(colour)
      fillText(text, 0, 0)
      restore()
    }

    /// Letter by letter with air between, for the small capitals along the top of a sheet.
    func trackedText(_ text: String, _ x: Float, _ y: Float, _ tracking: Float) {
      var cursor = x
      for character in text {
        let one = String(character)
        fillText(one, cursor, y)
        cursor += measure(one) + tracking
      }
    }

    func rule(_ x: Float, _ y: Float, _ width: Float, _ height: Float, _ colour: Colour) {
      fill(colour)
      fillRect(x, y, width, height)
    }

    func spectrum(
      _ bands: [Float], _ x: Float, _ y: Float, _ width: Float, _ height: Float, _ colour: Colour,
      _ gap: Float = 0.18
    ) {
      let lane = width / Float(bands.count)
      fill(colour)
      for (index, band) in bands.enumerated() {
        let value = 0.06 + min(1, band * 1.55)
        let barHeight = height * value
        fillRect(x + lane * Float(index), y + height - barHeight, lane * (1 - gap), barHeight)
      }
    }

    func paperGrain(_ frame: Frame, _ colour: Colour) {
      fill(colour)
      let amount = Int((frame.width * frame.height / 4200).rounded(.down))
      for index in 0..<max(0, amount) {
        let at = Double(index)
        let x = GraphicLabScene.hash(at * 2.13) * frame.width
        let y = GraphicLabScene.hash(at * 5.71) * frame.height
        let size = 0.5 + GraphicLabScene.hash(at * 8.9) * 1.7
        fillRect(x, y, size, size)
      }
    }

    func cropMarks(_ frame: Frame, _ colour: Colour) {
      let inset = max(15, frame.width * 0.022)
      let length = max(10, frame.width * 0.018)
      canvas.stroke = colour
      canvas.lineWidth = max(1, frame.width / 900)
      var lines: [(SIMD2<Float>, SIMD2<Float>)] = []
      for x in [inset, frame.width - inset] {
        lines.append((SIMD2(x - length, inset), SIMD2(x + length, inset)))
        lines.append((SIMD2(x, inset - length), SIMD2(x, inset + length)))
        lines.append((SIMD2(x - length, frame.height - inset), SIMD2(x + length, frame.height - inset)))
        lines.append((SIMD2(x, frame.height - inset - length), SIMD2(x, frame.height - inset + length)))
      }
      canvas.strokeLines(lines)
    }

    /// The web's `drawImage(canvas, 0, y, w, band, shift, y, w, band)`: the sheet printed onto
    /// itself with one band of it moved sideways. Source and destination are the same size, so
    /// what it amounts to is the whole sheet translated and clipped to the band it lands in.
    /// Each reads the sheet the one before it left — which is what makes a run of them read as a
    /// signal losing lock.
    func signalSlip(y: Float, band: Float, shift: Float) {
      save()
      canvas.clip(shift, y, Float(canvas.width), band)
      canvas.drawPage(shiftedBy: SIMD2(shift, 0))
      restore()
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

    /// A sheet: the edition printed, and the target it is in.
    func print(_ frame: Frame, edition: Int) throws -> any GPUTarget {
      try canvas.begin(width: Int(frame.width), height: Int(frame.height))
      if edition == 0 {
        pressEdition(frame)
      } else if edition == 1 {
        flyer(frame)
      } else {
        broadcast(frame)
      }
      return canvas.finish()
    }

    /// A / TYPE PRESS. Strict grid, two physical inks, the spectrum used as a rule rather than
    /// as a picture of itself.
    func pressEdition(_ frame: Frame) {
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
        portrait ? "DBX / EDITION A" : "DRIFTBOX / TYPE PRESS / EDITION A", margin, h * 0.068, w * 0.003)
      align = .right
      let count = "\(GraphicLabScene.pad(frame.bar + 1)) : \(GraphicLabScene.pad(frame.step + 1))"
      fillText(count, w - margin, h * 0.068)
      align = .left

      // Two physical inks, slightly out of register when the top end gets busy.
      let register = 2 + frame.high * 10
      save()
      canvas.clip(0, h * 0.15, w, h * 0.48)
      if portrait {
        let lines = titleLines(frame.title.uppercased())
        for (index, line) in [lines.0, lines.1].enumerated() {
          let baseline = h * (0.36 + Float(index) * 0.215)
          fittedText(line, margin + register, baseline + pulse, w * 0.89, h * 0.215, red)
          fittedText(line, margin - register, baseline - pulse, w * 0.89, h * 0.215, blue)
          canvas.blend = .multiply
          fittedText(line, margin, baseline, w * 0.89, h * 0.215, ink)
          canvas.blend = .normal
        }
      } else {
        let title = frame.title.uppercased()
        fittedText(title, margin + register, h * 0.43 + pulse, w * 0.91, h * 0.29, red)
        fittedText(title, margin - register, h * 0.405 - pulse, w * 0.91, h * 0.29, blue)
        canvas.blend = .multiply
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

      cropMarks(frame, Colour(0x14_130f, alpha: 0.65))
      paperGrain(frame, Colour(0x14_130f, alpha: 0.08))
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
            GraphicLabScene.bandCount - 1, Int((x / w * Float(GraphicLabScene.bandCount)).rounded(.down)))
          let energy = frame.bands[max(0, lane)]
          let wave = 0.5 + 0.5 * sin(x * 0.025 + y * 0.018 - frame.time * 3)
          let radius = spacing * (0.07 + energy * 0.25 + wave * 0.08)
          canvas.fillEllipse(x - radius, y - radius, radius * 2, radius * 2)
          x += spacing
        }
        y += spacing
      }

      save()
      canvas.translate(w * 0.5, h * (portrait ? 0.31 : 0.29))
      canvas.rotate(-0.045 + frame.high * 0.018)
      rule(-w * 0.58, -h * (portrait ? 0.23 : 0.17), w * 1.16, h * (portrait ? 0.46 : 0.34), cream)
      if portrait {
        let lines = titleLines(frame.title.uppercased())
        for (index, line) in [lines.0, lines.1].enumerated() {
          let baseline = h * (-0.015 + Float(index) * 0.19)
          fittedText(line, -w * 0.48 + frame.high * 8, baseline + kick, w * 0.96, h * 0.18, pink)
          canvas.blend = .multiply
          fittedText(line, -w * 0.48 - frame.high * 8, baseline - kick, w * 0.96, h * 0.18, black)
          canvas.blend = .normal
        }
      } else {
        let title = frame.title.uppercased()
        fittedText(title, -w * 0.48 + frame.high * 8, h * 0.09 + kick, w * 0.96, h * 0.235, pink)
        canvas.blend = .multiply
        fittedText(title, -w * 0.48 - frame.high * 8, h * 0.075 - kick, w * 0.96, h * 0.235, black)
      }
      restore()

      save()
      canvas.translate(w * 0.12, h * 0.6)
      canvas.rotate(0.025)
      rule(0, 0, w * 0.76, h * 0.115, black)
      // Kept on its slab: at a size taken from the height, in portrait the name ran off it.
      fittedText(frame.section.uppercased(), w * 0.025, h * 0.082, w * 0.71, h * 0.07, cream)
      restore()

      // Photocopied repetition — the label becomes texture before it becomes information.
      save()
      canvas.clip(0, h * 0.7, w, h * 0.22)
      setFont(h * 0.047)
      for row in 0..<6 {
        let slip = sin(frame.time * 2.1 + Float(row) * 1.7) * frame.high * w * 0.045
        fill(row % 2 == 1 ? black : pink)
        fillText(
          "DRIFTBOX \(frame.bpm) BPM DRIFTBOX \(frame.bpm) BPM", -w * 0.08 + slip,
          h * (0.735 + Float(row) * 0.045))
      }
      restore()

      rule(margin, h * 0.93, w - margin * 2, h * 0.045, black)
      fill(yellow)
      setFont(h * 0.018, 700, .text)
      let bar = "B / XEROX NIGHT / BAR \(GraphicLabScene.pad(frame.bar + 1))"
      fillText(portrait ? "B / XEROX" : bar, margin * 1.35, h * 0.96)
      align = .right
      fillText(portrait ? "DOT / TEAR" : "INK / DOT / REPEAT / TEAR", w - margin * 1.35, h * 0.96)
      align = .left

      cropMarks(frame, black)
      paperGrain(frame, Colour(0x11_100e, alpha: 0.16))
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

      // Each line of the grid is stroked on its own, as the web strokes them, so where two cross
      // the crossing is inked twice there too.
      canvas.stroke = Colour(red: 245 / 255, green: 243 / 255, blue: 233 / 255, alpha: 0.18)
      canvas.lineWidth = 1
      var x: Float = 0
      while x <= w {
        canvas.strokeLines([(SIMD2(x, 0), SIMD2(x, h))])
        x += w / 12
      }
      var y: Float = 0
      while y <= h {
        canvas.strokeLines([(SIMD2(0, y), SIMD2(w, y))])
        y += h / 8
      }

      rule(0, h * 0.055, w * (0.2 + phase * 0.8), h * 0.035, orange)
      rule(w * (0.84 - phase * 0.4), h * 0.105, w * 0.5, h * 0.012, white)

      fill(white)
      setFont(h * 0.024, 700, .text)
      trackedText("DBX / LIVE SIGNAL", margin, h * 0.165, w * 0.0025)
      align = .right
      fillText("CH \(GraphicLabScene.pad(frame.bar % 12 + 1))", w - margin, h * 0.165)
      align = .left

      let initials = frame.title.split(whereSeparator: { $0.isWhitespace }).compactMap { $0.first }
      let monogram = String(initials.prefix(3))
      save()
      canvas.clip(0, h * 0.18, w, h * 0.49)
      let jump = frame.bass * h * 0.03
      fittedText(
        (monogram.isEmpty ? "DBX" : monogram).uppercased(), margin, h * 0.61 + jump, w * 0.92, h * 0.54, white
      )

      // Signal slips are hard horizontal copies, not a soft digital "glitch" effect.
      for slice in 0..<5 {
        let at = Double(slice)
        let top = h * (0.25 + GraphicLabScene.hash(at * 8.3) * 0.34)
        let band = h * (0.012 + GraphicLabScene.hash(at * 3.1) * 0.025)
        let seed = at * 7.7 + (frame.clock * 8).rounded(.down)
        let shift = (GraphicLabScene.hash(seed) - 0.5) * frame.high * w * 0.24
        signalSlip(y: top, band: band, shift: shift)
      }
      restore()

      rule(0, h * 0.68, w, h * 0.12, orange)
      fittedText(frame.section.uppercased(), margin, h * 0.765, w - margin * 2, h * 0.074, black)

      let seconds = Int(frame.time.rounded(.down))
      let timecode =
        "\(GraphicLabScene.pad(seconds / 60)):\(GraphicLabScene.pad(seconds % 60))"
        + ":\(GraphicLabScene.pad(frame.bar + 1)):\(GraphicLabScene.pad(frame.step + 1))"
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
}
