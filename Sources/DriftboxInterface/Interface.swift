import DriftboxCanvas
import DriftboxEngine
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Foundation

/// Driftbox's controls, drawn on a canvas over the scene: the transport along the top, and the step
/// grid for the pattern the transport is in, or the one chosen to edit. The same on every platform;
/// it reads the session and edits it, and knows nothing of windows but the pointer.
///
/// It is drawn in points, under whatever scale the page has to its pixels, and made afresh each
/// frame from the session: there is no view tree to keep in step, only a layout, which the pointer
/// reads as the drawing did.
///
/// A press on a panel is the interface's until it lifts, wherever it goes meanwhile, and does what
/// it was pressed on if it lifts there, as a button does. Anywhere else is not the interface's.
@MainActor
public final class Interface {
  public let session: Session
  /// Whether the controls are showing. Hidden, the whole window is the scene and the pad, for
  /// performing.
  public var isShowing = true {
    didSet { if !isShowing { pressed = nil } }
  }
  /// The window's size in points, which the last frame was laid out for.
  public var size: SIMD2<Float> = .zero
  /// Where the pointer is over the window, if it is, for what it is over to brighten.
  public private(set) var hover: SIMD2<Float>?
  /// A press the interface has, and what it was pressed on.
  public private(set) var pressed: (pointer: Int, action: Action?)?

  /// How far the grid is scrolled up inside its panel.
  public private(set) var scroll: Float = 0

  public init(session: Session) {
    self.session = session
  }

  public var layout: Layout { Layout(session: session, size: size, scroll: scroll) }

  /// Scroll the grid, if `event` is over it. False for anywhere else.
  @discardableResult
  public func scroll(_ event: ScrollEvent) -> Bool {
    guard isShowing, let grid = layout.grid, grid.contains(event.location) else { return false }
    scroll = Layout(session: session, size: size, scroll: scroll + event.delta.y).scroll
    return true
  }

  // MARK: - The pointer

  /// Take `event` if it is the interface's: a press on a panel, and everything that press does until
  /// it lifts. False for anything else, which is the pad's.
  public func pointer(_ event: PointerEvent) -> Bool {
    if event.kind == .mouse { hover = event.phase == .cancelled ? nil : event.location }
    guard isShowing else { return false }
    switch event.phase {
    case .began:
      let layout = layout
      guard layout.panels.contains(where: { $0.contains(event.location) }) else { return false }
      pressed = (event.id, layout.action(at: event.location))
      return true
    case .moved:
      return pressed?.pointer == event.id
    case .ended:
      guard let press = pressed, press.pointer == event.id else { return false }
      pressed = nil
      if let action = press.action, layout.action(at: event.location) == action {
        perform(action, modifiers: event.modifiers)
      }
      return true
    case .cancelled:
      guard pressed?.pointer == event.id else { return false }
      pressed = nil
      return true
    }
  }

  /// The pointer has left the window.
  public func pointerLeft() { hover = nil }

  public func perform(_ action: Action, modifiers: Modifiers = []) {
    switch action {
    case .toggle: session.toggle()
    case .start: session.seek(toStep: 0)
    case .loop: session.loopSection()
    case .metronome: session.metronome.toggle()
    case .select(let voice):
      session.selectedVoice = session.selectedVoice == voice ? nil : voice
    case .filterStep(let pattern, let index):
      session.editPattern(pattern, "Set Filter Step") { $0.cyclingPCF(at: index) }
    case .step(let pattern, let voice, let index):
      // A 909 step flams rather than cycles in flam mode, or with the option key held.
      let flamming = voice.hasPrefix("909.") && (session.flamMode || modifiers.contains(.option))
      session.editPattern(pattern, flamming ? "Set Flam" : "Set Step") {
        flamming ? $0.togglingFlam(voice, at: index) : $0.cyclingStep(voice, at: index)
      }
    case .note(let pattern, let voice, let index, let note):
      editBass(pattern, voice, index, "Set Note") { step in
        // The note that is already set, pressed again, pauses the step and keeps its pitch.
        if Int(step.note ?? -1) == note, step.sounds {
          step = step.settingGate(false)
        } else {
          step.note = Double(note)
          step = step.settingGate(true)
        }
      }
    case .bassAccent(let pattern, let voice, let index):
      editBass(pattern, voice, index, "Set Accent") { $0.accent.toggle() }
    case .bassSlide(let pattern, let voice, let index):
      editBass(pattern, voice, index, "Set Slide") { $0 = $0.settingSlide(!$0.slide) }
    }
  }

  private func editBass(
    _ pattern: String, _ voice: String, _ index: Int, _ name: String, _ change: (inout BassStep) -> Void
  ) {
    session.editPattern(pattern, name) { pattern in
      var step = pattern.bassStep(voice, at: index)
      change(&step)
      return pattern.settingBassStep(voice, at: index, to: step)
    }
  }

  // MARK: - Drawing

  /// Everything, onto `canvas`, whose transform takes points to its pixels.
  public func draw(on canvas: Canvas) {
    guard isShowing else { return }
    let layout = layout
    // Kept to what there is, should the window have grown or the pattern shrunk.
    scroll = layout.scroll
    held = pressed.flatMap { press in
      hover.flatMap { layout.action(at: $0) == press.action ? press.action : nil }
    }
    drawBar(layout, on: canvas)
    drawGrid(layout, on: canvas)
  }

  private func isHovered(_ rect: Rect) -> Bool { hover.map(rect.contains) ?? false }

  /// What is held down and still under the pointer, this frame: what draws as pressed.
  private var held: Action?

  private func isPressed(_ action: Action) -> Bool { held == action }

  private func panel(_ rect: Rect, on canvas: Canvas) {
    canvas.fill = Theme.panel
    canvas.fillRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: 12)
    canvas.stroke = Theme.edge
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(rect.x, rect.y, rect.width, rect.height, radius: 12)
  }

  private func drawBar(_ layout: Layout, on canvas: Canvas) {
    panel(layout.bar, on: canvas)
    for chip in layout.chips {
      self.chip(chip, on: canvas)
    }
    let baseline = layout.bar.y + layout.bar.height / 2 + 5
    canvas.save()
    canvas.clip(layout.title.x, layout.title.y, layout.title.width, layout.title.height)
    canvas.font = Theme.mono(13, weight: 600)
    canvas.fill = Theme.ink
    canvas.align = .left
    canvas.fillText(session.song == nil ? "No song" : session.documentName, layout.title.x, baseline)
    canvas.restore()

    guard session.song != nil else { return }
    canvas.save()
    canvas.clip(layout.readout.x, layout.readout.y, layout.readout.width, layout.readout.height)
    canvas.font = Theme.mono(11)
    canvas.align = .right
    let bpm = session.tempo
    let tempo = bpm == bpm.rounded() ? "\(Int(bpm))" : String(format: "%.1f", bpm)
    canvas.fill = Theme.dim
    canvas.fillText("\(tempo) BPM", layout.readout.maxX, baseline)
    let tempoWidth = canvas.measure("\(tempo) BPM")
    let bar = (session.position?.bar ?? 0) + 1
    let step = (session.position?.step ?? 0) + 1
    canvas.fill = session.isPlaying ? Theme.live : Theme.ink
    canvas.fillText(
      "BAR \(bar)  \(step)/\(layout.pattern?.length ?? 16)", layout.readout.maxX - tempoWidth - 18, baseline)
    canvas.restore()
  }

  /// A button as the web draws one: a dark rounded chip with a hairline edge that brightens under
  /// the pointer, lit in teal when it is on.
  private func chip(_ chip: Layout.Chip, on canvas: Canvas) {
    let frame = chip.frame
    let hovered = isHovered(frame)
    let down = isPressed(chip.action)
    let tint = Theme.nine
    canvas.fill = chip.isOn ? tint.faded(0.12) : Theme.white(down ? 0.1 : 0.045)
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.stroke = chip.isOn ? tint.faded(0.9) : Theme.white(hovered ? 0.3 : 0.1)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.font = Theme.mono(11)
    canvas.fill = chip.isOn ? tint : Theme.ink.faded(0.92)
    canvas.align = .center
    canvas.fillText(chip.label, frame.x + frame.width / 2, frame.y + frame.height / 2 + 4)
  }

  private func drawGrid(_ layout: Layout, on canvas: Canvas) {
    guard let grid = layout.grid, let pattern = layout.pattern, let metrics = layout.metrics else { return }
    panel(grid, on: canvas)
    canvas.save()
    canvas.clip(grid.x + 1, grid.y + 1, grid.width - 2, grid.height - 2)

    // The ruler: every fourth tick brighter, so a bar reads in beats, and the playhead's tall and lit.
    if let ruler = layout.ruler {
      for step in 0..<metrics.steps {
        let x = ruler.x + Float(step) * metrics.stride
        let live = step == layout.playhead
        canvas.fill = live ? Theme.live : Theme.white(step % 4 == 0 ? 0.2 : 0.09)
        let height: Float = live ? 8 : 4
        canvas.fillRoundedRect(x, ruler.maxY - height, metrics.cell, height, radius: 2)
      }
    }

    for lane in layout.lanes {
      let voice = lane.voice
      let selected = session.selectedVoice == voice.id
      if selected {
        canvas.fill = Theme.white(0.06)
        canvas.fillRoundedRect(lane.frame.x, lane.frame.y, lane.frame.width, lane.frame.height, radius: 8)
      }
      // The lane's light, which flashes in its machine's colour as the voice strikes.
      let struck = session.struck.contains(lane.index)
      let tint = Theme.colour(voice.machine)
      let middle = lane.header.y + lane.header.height / 2
      if struck {
        canvas.fill = tint.faded(0.3)
        canvas.fillEllipse(lane.header.x - 3, middle - 6, 12, 12)
      }
      canvas.fill = struck ? tint : Theme.white(0.12)
      canvas.fillEllipse(lane.header.x, middle - 3, 6, 6)
      canvas.font = Theme.mono(11, weight: selected ? 600 : 400)
      canvas.fill = selected || isHovered(lane.header) ? Theme.ink : Theme.dim
      canvas.align = .left
      canvas.save()
      canvas.clip(lane.header.x, lane.header.y, lane.header.width - 8, lane.header.height)
      canvas.fillText(voice.name, lane.header.x + 13, middle + 4)
      canvas.restore()

      let loop = pattern.trackLength(voice.id)
      for index in 0..<pattern.length {
        face(
          layout.step(index, in: lane.frame), value: pattern.step(voice.id, at: index),
          fill: Theme.stepFill(voice.machine), playing: index == layout.playhead, onBeat: index % 4 == 0,
          flam: pattern.flam(voice.id, at: index), tail: index >= loop,
          action: .step(pattern: pattern.id, voice: voice.id, index: index), on: canvas)
      }
    }

    // The pattern-controlled filter's lane, on the drums' columns, in teal.
    if let lane = layout.filterLane {
      canvas.fill = Theme.nine.faded(0.18)
      canvas.fillRect(lane.x + 4, lane.y - 5, lane.width - 8, 1)
      let middle = lane.y + lane.height / 2
      canvas.fill = Theme.nine.faded(0.35)
      canvas.fillEllipse(lane.x + 4, middle - 3, 6, 6)
      canvas.font = Theme.mono(11, weight: 500)
      canvas.fill = Theme.nine
      canvas.align = .left
      canvas.fillText("PCF", lane.x + 17, middle + 4)
      for index in 0..<pattern.length {
        face(
          layout.step(index, in: lane), value: pattern.pcf(at: index), fill: Theme.stepFill(.tr909),
          playing: index == layout.playhead, onBeat: index % 4 == 0, flam: false, tail: false,
          action: .filterStep(pattern: pattern.id, index: index), on: canvas)
      }
    }
    for line in layout.bassLines {
      drawBassLine(line, layout, pattern: pattern, metrics: metrics, on: canvas)
    }
    canvas.restore()

    // Where the grid is scrolled to, when it is taller than its panel.
    if layout.maxScroll > 0 {
      let track = grid.height - 24
      let thumb = max(24, track * grid.height / (grid.height + layout.maxScroll))
      let top = grid.y + 12 + (track - thumb) * layout.scroll / layout.maxScroll
      canvas.fill = Theme.white(0.18)
      canvas.fillRoundedRect(grid.maxX - 7, top, 3, thumb, radius: 1.5)
    }
  }

  /// A 303 line: for each step, whether it sounds, its pitch across two octaves, accent and slide,
  /// on the drums' columns, so a note sits under the kick it plays against. A paused step shows
  /// where its pitch is, as an outline.
  private func drawBassLine(
    _ line: Layout.BassLine, _ layout: Layout, pattern: DriftboxSeq.Pattern, metrics: GridMetrics,
    on canvas: Canvas
  ) {
    let selected = session.selectedVoice == line.voice
    if selected {
      canvas.fill = Theme.white(0.06)
      canvas.fillRoundedRect(line.frame.x, line.frame.y, line.frame.width, line.frame.height, radius: 8)
    }
    // The header: the machine, the line's name, and the octaves and the flag rows named level with
    // their rows.
    let header = line.header
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 600)
    canvas.fill = Theme.three
    canvas.fillText("TB-303", header.x, header.y + 9)
    canvas.font = Theme.mono(12, weight: 600)
    canvas.fill = selected || isHovered(header) ? Theme.ink : Theme.ink.faded(0.8)
    canvas.fillText(line.name, header.x, header.y + 24)
    let right = line.cells.x - 14
    let cells = line.cells
    canvas.align = .right
    canvas.font = Theme.mono(8)
    canvas.fill = Theme.dim.faded(0.7)
    for note in [24, 12, 0] {
      canvas.fillText("C\(note / 12 + 1)", right, cells.y + Float(24 - note) * BassMetrics.noteStride + 6)
    }
    canvas.font = Theme.mono(8, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText("ACCENT", right, cells.y + BassMetrics.flagsTop + 10)
    canvas.fillText("SLIDE", right, cells.y + BassMetrics.flagsTop + BassMetrics.flagStride + 10)

    // The keyboard behind the cells: the black keys' rows darker.
    canvas.fill = Colour(0x000000, alpha: 0.28)
    for (row, note) in BassMetrics.notes.enumerated() where BassMetrics.blackKeys.contains(note % 12) {
      canvas.fillRect(
        cells.x, cells.y + Float(row) * BassMetrics.noteStride - 1, cells.width, BassMetrics.noteStride)
    }
    if let playhead = layout.playhead, playhead < pattern.length {
      // Lighter than the drums' playhead: a column this tall at full strength would be the
      // brightest thing in the window, and it only says where the drums already say.
      let x = cells.x + Float(playhead) * metrics.stride - 1
      canvas.fill = Theme.live.faded(0.09)
      canvas.fillRoundedRect(x, cells.y - 1, metrics.cell + 2, BassMetrics.notesHeight, radius: 3)
      canvas.stroke = Theme.live.faded(0.3)
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(x, cells.y - 1, metrics.cell + 2, BassMetrics.notesHeight, radius: 3)
    }

    var lit: [(Rect, Bool)] = []
    for index in 0..<pattern.length {
      let step = pattern.bassStep(line.voice, at: index)
      let blank = Theme.white(index % 4 == 0 ? 0.07 : 0.035)
      for note in BassMetrics.notes {
        let cell = layout.noteCell(note, step: index, in: line)
        if Int(step.note ?? -1) == note {
          lit.append((cell, step.sounds))
        } else {
          canvas.fill = isHovered(cell) ? Theme.white(0.16) : blank
          canvas.fillRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 2)
        }
      }
      for slide in [false, true] {
        let flag = layout.flagCell(step: index, slide: slide, in: line)
        let on = slide ? step.slide : step.accent
        canvas.fill = on ? (slide ? Theme.violet : Theme.three) : isHovered(flag) ? Theme.white(0.14) : blank
        canvas.fillRoundedRect(flag.x, flag.y, flag.width, flag.height, radius: 3)
      }
    }
    // The notes last, glowing, over everything; a paused one only an outline of where it would be.
    for (cell, sounds) in lit {
      if sounds {
        let glow = cell.outset(3)
        canvas.fill = Theme.three.faded(0.28)
        canvas.fillRoundedRect(glow.x, glow.y, glow.width, glow.height, radius: 5)
        canvas.fill = Colour(0xffde96)
        canvas.fillRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 2, foot: Theme.three)
      } else {
        canvas.stroke = Theme.three.faded(0.55)
        canvas.lineWidth = 1
        canvas.strokeRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 2)
      }
    }
  }

  /// One step: off, on, or accented, lit top to bottom; the playhead's column outlined in teal all
  /// the way down; a flam's second strike a bright edge on its right. A step past the end of a lane
  /// that loops shorter than the pattern is faint, and does nothing.
  private func face(
    _ frame: Rect, value: StepValue, fill: (top: Colour, foot: Colour), playing: Bool, onBeat: Bool,
    flam: Bool, tail: Bool, action: Action, on canvas: Canvas
  ) {
    let opacity: Float = tail ? 0.28 : 1
    let down = isPressed(action)
    // A press gives, a little, under the pointer.
    let shape = down ? frame.outset(-1.5) : frame
    let radius: Float = 5
    func rounded(_ colour: Colour, _ rect: Rect = shape, radius: Float = radius, foot: Colour? = nil) {
      canvas.fill = colour.faded(opacity)
      canvas.fillRoundedRect(
        rect.x, rect.y, rect.width, rect.height, radius: radius, foot: foot?.faded(opacity))
    }

    // Glows first, under the step.
    if playing {
      rounded(Theme.live.faded(value == .off ? 0.12 : 0.22), shape.outset(4), radius: radius + 4)
    } else if value == .accent {
      rounded(Theme.accentGlow.faded(0.22), shape.outset(3), radius: radius + 3)
    }
    rounded(Theme.white(onBeat ? 0.075 : 0.03))
    switch value {
    case .on: rounded(fill.top, foot: fill.foot)
    case .accent: rounded(Theme.accentFill.top, foot: Theme.accentFill.foot)
    case .off: break
    }
    if playing { rounded(Theme.live.faded(value == .off ? 0.2 : 0.12)) }
    if flam {
      rounded(Theme.white(0.72), Rect(shape.maxX - 6, shape.y + 3, 3, shape.height - 6), radius: 1.5)
    }
    let edge: Colour =
      switch value {
      case .accent: Theme.white(1)
      case .on: Theme.white(0.5)
      case .off: Theme.white(!tail && isHovered(frame) ? 0.45 : 0.1)
      }
    canvas.stroke = edge.faded(opacity)
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(shape.x, shape.y, shape.width, shape.height, radius: radius)
    if playing {
      let ring = shape.outset(3.5)
      canvas.stroke = Theme.live
      canvas.lineWidth = 2
      canvas.strokeRoundedRect(ring.x, ring.y, ring.width, ring.height, radius: radius + 3.5)
    }
  }
}
