import DriftboxCanvas
import DriftboxEngine
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Foundation

// C's maths, which Foundation brings with it on Apple's platforms and not on Android.
#if canImport(Android)
  import Android
#endif

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
    didSet {
      if !isShowing {
        pressed = nil
        if turning != nil { session.endTurn() }
        turning = nil
      }
    }
  }
  /// The window's size in points, which the last frame was laid out for.
  public var size: SIMD2<Float> = .zero
  /// Whether it is on a touchscreen, and laid out for fingers however wide: a tablet's controls, as
  /// a roomier phone's. Narrower than `Layout.compactWidth` it is a phone's either way.
  public var touch = false
  /// Where the pointer is over the window, if it is, for what it is over to brighten.
  public private(set) var hover: SIMD2<Float>?
  /// A press the interface has, and what it was pressed on.
  public private(set) var pressed: (pointer: Int, action: Action?)?

  /// How far the grid is scrolled up inside its panel.
  public private(set) var scroll: Float = 0
  /// How far its steps are scrolled left, when they are wider than it.
  public private(set) var scrollX: Float = 0
  /// Where the steps are paged, which eight the grid shows, and whether that follows the playhead:
  /// it does until a page is chosen, and again once the pattern playing is followed.
  public private(set) var page = 0
  public private(set) var followsPage = true
  /// On a touchscreen, whether the controls are put away for performing: the whole screen the scene
  /// and the pad but for one chip in the corner, which brings them back.
  public var performing = false {
    didSet {
      if performing {
        pressed = nil
        if turning != nil { session.endTurn() }
        turning = nil
      }
    }
  }
  /// A finger dragged on the grid rather than tapped: which, from where, where it was last, and
  /// which way it went once it had gone far enough to say.
  private var drag: (pointer: Int, from: SIMD2<Float>, last: SIMD2<Float>, across: Bool?)?
  /// On a touchscreen, the 303 step the keyboard is setting, if it is showing, and the keyboard's
  /// octave.
  public private(set) var bassSelection: (voice: String, index: Int)?
  public private(set) var octave = 0
  /// Whether the song's effects are down the right, where the selected voice's knobs would be.
  public var showsEffects = false
  /// A pattern being renamed, and its name as it has been typed so far.
  public internal(set) var renaming: (pattern: String, text: String)?
  /// Whether keys are the renaming's rather than the instrument's or the menus'.
  public var takesText: Bool { renaming != nil }
  /// The context menu last made: what each of its commands does, and which are greyed or ticked.
  var menuActions: [String: () -> Void] = [:]
  /// A menu a tap asked for — the song's — for the platform to show as its own.
  var menuRequest: (menu: Menu, at: SIMD2<Float>)?

  /// What the song's menu asks of its file, which only the platform can do: choose one to open, or
  /// where to save it, with its own pickers.
  public enum FileAction: Sendable, Equatable {
    case open, save, saveAs
  }
  /// Where the song's menu sends what it asks of a file; with none, it offers none.
  public var files: ((FileAction) -> Void)?
  /// Ask whether to go on and lose the song's unsaved edits, and do `then` if so; with none, the
  /// interface goes on without asking.
  public var confirm: ((_ question: String, _ then: @escaping () -> Void) -> Void)?
  var menuDisabled: Set<String> = []
  var menuChecked: Set<String> = []

  public init(session: Session) {
    self.session = session
  }

  public var layout: Layout {
    layout(scroll: scroll)
  }

  /// The layout as it is but for the grid scrolled up by `scroll` and left by `scrollX`.
  func layout(scroll: Float, scrollX: Float? = nil) -> Layout {
    Layout(
      session: session, size: size, scroll: scroll, scrollX: scrollX ?? self.scrollX, effects: showsEffects,
      renaming: renaming, page: page, keyboard: bassSelection != nil, touch: touch)
  }

  /// Where the chip that brings the controls back is, while performing.
  public var editChip: Rect { Rect(size.x - Layout.margin - 64, Layout.margin, 64, 32) }

  /// On a touchscreen, the keyboard the selected 303 step's note is set on, while one is selected.
  public var keyboard: BassKeyboard? { keyboard(in: layout) }

  func keyboard(in layout: Layout) -> BassKeyboard? {
    guard layout.touch, let selection = bassSelection else { return nil }
    return BassKeyboard(layout: layout, voice: selection.voice, index: selection.index, octave: octave)
  }

  /// What a press at `point` does: the keyboard's, where it covers the rest, or the layout's.
  func action(at point: SIMD2<Float>, in layout: Layout) -> Action? {
    if let keyboard = keyboard(in: layout), keyboard.frame.contains(point), let pattern = layout.pattern {
      return keyboard.action(at: point, pattern: pattern.id)
    }
    return layout.action(at: point)
  }

  /// Scroll the grid, if `event` is over it. False for anywhere else.
  @discardableResult
  public func scroll(_ event: ScrollEvent) -> Bool {
    guard isShowing, let grid = layout.grid, grid.contains(event.location) else { return false }
    // Sideways as a wheel tilts, or as it turns with Shift held, as Windows' own programs take it.
    let sideways = event.modifiers.contains(.shift) ? event.delta.y + event.delta.x : event.delta.x
    let down = event.modifiers.contains(.shift) ? 0 : event.delta.y
    let moved = layout(scroll: scroll + down, scrollX: scrollX + sideways)
    scroll = moved.scroll
    scrollX = moved.scrollX
    return true
  }

  // MARK: - The pointer

  /// Take `event` if it is the interface's: a press on a panel, and everything that press does until
  /// it lifts. False for anything else, which is the pad's: what a window with a pad asks, and
  /// one without, as a phone's, has no need to.
  @discardableResult
  public func pointer(_ event: PointerEvent) -> Bool {
    if event.kind == .mouse { hover = event.phase == .cancelled ? nil : event.location }
    guard isShowing else { return false }
    if performing { return editChipPointer(event) }
    switch event.phase {
    case .began:
      // A press anywhere keeps the name being typed, as leaving a field does.
      if renaming != nil { finishRenaming() }
      let layout = layout
      if let keyboard = keyboard(in: layout), keyboard.frame.contains(event.location) {
        // The keyboard sits over the rest, and a press on it is its own.
        pressed = (event.id, self.action(at: event.location, in: layout))
        return true
      }
      guard layout.panels.contains(where: { $0.contains(event.location) }) else { return false }
      let action = layout.action(at: event.location)
      pressed = (event.id, action)
      if case .knob(let target) = action, let song = session.song {
        let value = target.value(in: song)
        turning = Turn(pointer: event.id, target: target, fromY: event.location.y, from: value, value: value)
      } else if event.kind != .mouse, layout.gridContent?.contains(event.location) == true {
        // A finger on the grid may be about to drag it rather than tap it: a wheel's work, and a
        // swipe's, where there is no wheel.
        drag = (event.id, event.location, event.location, nil)
      }
      return true
    case .moved where drag?.pointer == event.id:
      guard var moving = drag else { return true }
      let moved = event.location - moving.from
      if moving.across == nil, (moved * moved).sum() > 100 {
        // Far enough to be a drag, and no longer the tap it began as.
        moving.across = abs(moved.x) > abs(moved.y)
        pressed = (event.id, nil)
      }
      if moving.across == false {
        let up = moving.last.y - event.location.y
        scroll = layout(scroll: scroll + up).scroll
      } else if moving.across == true, layout.maxScrollX > 0 {
        // Steps wider than the grid, and not paged, are dragged along under the names instead.
        let left = moving.last.x - event.location.x
        scrollX = layout(scroll: scroll, scrollX: scrollX + left).scrollX
      }
      moving.last = event.location
      drag = moving
      return true
    case .moved:
      if var turn = turning, turn.pointer == event.id {
        // Up turns it up. Option held turns it slower, for fine work: a knob a quarter as fast, a
        // number a fifth.
        let target = turn.target
        let fine = event.modifiers.contains(.option) ? (target.isNumber ? 0.2 : 0.25) : 1
        let moved = turn.from + Double(turn.fromY - event.location.y) * target.perPoint * fine
        let value = min(target.range.upperBound, max(target.range.lowerBound, moved))
        let next = target.isNumber ? value.rounded() : value
        if next != turn.value {
          // Heard as it turns, and recorded as it turns when automation is armed: the song takes
          // each move, and undo the whole turn once it is let go.
          session.turn(
            target.editName, automating: target.automationTarget, value: target.songValue(next),
            interpolation: target.interpolation
          ) { target.set(next, in: &$0) }
        }
        turn.value = next
        turning = turn
      }
      return pressed?.pointer == event.id
    case .ended:
      guard let press = pressed, press.pointer == event.id else { return false }
      pressed = nil
      if let swipe = drag, swipe.pointer == event.id {
        drag = nil
        // Swiped across: the next page to the left, the one before to the right, as a page turns.
        let across = event.location.x - swipe.from.x
        if swipe.across == true, abs(across) > 40, let pages = layout.metrics?.pages, pages > 1 {
          page = min(pages - 1, max(0, page + (across < 0 ? 1 : -1)))
          followsPage = false
        }
      }
      if let turn = turning, turn.pointer == event.id {
        turning = nil
        finish(turn)
      } else if let action = press.action, self.action(at: event.location, in: layout) == action {
        perform(action, modifiers: event.modifiers)
      }
      return true
    case .cancelled:
      guard pressed?.pointer == event.id else { return false }
      pressed = nil
      if turning != nil { session.endTurn() }
      turning = nil
      drag = nil
      return true
    }
  }

  /// While performing, the one chip in the corner is all there is of the controls: a finger
  /// anywhere else is the pad's.
  private func editChipPointer(_ event: PointerEvent) -> Bool {
    switch event.phase {
    case .began:
      guard editChip.contains(event.location) else { return false }
      pressed = (event.id, .perform)
      return true
    case .moved:
      return pressed?.pointer == event.id
    case .ended:
      guard pressed?.pointer == event.id else { return false }
      pressed = nil
      if editChip.contains(event.location) { performing = false }
      return true
    case .cancelled:
      guard pressed?.pointer == event.id else { return false }
      pressed = nil
      return true
    }
  }

  /// A knob being turned: by which pointer, from where, and what it was and is.
  public struct Turn: Equatable {
    public var pointer: Int
    public var target: KnobTarget
    public var fromY: Float
    public var from: Double
    public var value: Double
  }

  /// The knob being turned, which the song hears as it turns and keeps as one step of undo once it is
  /// let go.
  public private(set) var turning: Turn?
  /// A knob pressed and let go without turning, and when: a second, soon after, puts it back.
  private var lastTap: (target: KnobTarget, at: ContinuousClock.Instant)?
  private func finish(_ turn: Turn) {
    session.endTurn()
    if turn.value != turn.from {
      lastTap = nil
      return
    }
    let now = ContinuousClock.now
    if let last = lastTap, last.target == turn.target, now - last.at < .milliseconds(400) {
      lastTap = nil
      if let rest = turn.target.rest, turn.from != rest {
        let target = turn.target
        session.turn(
          target.editName, automating: target.automationTarget, value: target.songValue(rest),
          interpolation: target.interpolation
        ) { target.set(rest, in: &$0) }
        session.endTurn()
      }
    } else {
      lastTap = (turn.target, now)
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
    case .automation: session.recordsAutomation.toggle()
    case .select(let voice):
      // Its knobs, in the effects' place if they are there. On a phone, where they are a sheet
      // at the foot of the screen, the 303 keyboard goes: there is no room for both.
      session.selectedVoice = session.selectedVoice == voice && !showsEffects ? nil : voice
      showsEffects = false
      bassSelection = nil
    case .show(let voice):
      session.selectedVoice = voice
      showsEffects = false
      bassSelection = nil
    case .effects:
      showsEffects.toggle()
      bassSelection = nil
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
      // From the keyboard: heard as it is set, and on to the next step, as a 303 takes its notes.
      if let selection = bassSelection, selection.voice == voice, selection.index == index,
        let shown = session.shownPattern
      {
        let step = shown.bassStep(voice, at: index)
        if step.sounds { session.playNote(semitone: note - 12, accent: step.accent) }
        select(bass: voice, (index + 1) % shown.length, keepingOctave: true)
      }
    case .bassAccent(let pattern, let voice, let index):
      editBass(pattern, voice, index, "Set Accent") { $0.accent.toggle() }
    case .hit(let voice):
      if let index = session.usedVoices.firstIndex(where: { $0.id == voice }) {
        session.strike(index: index, accent: false)
      }
    case .seek(let bar):
      session.seek(toBar: bar)
    case .follow:
      session.editing = nil
      followsPage = true
    case .showPattern(let id):
      session.editing = id
    case .addPattern:
      let length = session.shownPattern?.length ?? 16
      var added: String?
      session.edit("Add Pattern") { song in
        let result = song.addingPattern(length: length)
        song = result.song
        added = result.id
      }
      // Made in order to be worked on: it is the one shown.
      if let added { session.editing = added }
    case .close:
      session.selectedVoice = nil
    case .knob:
      // Turned by dragging, which the pointer does; a knob does nothing when merely let go.
      break
    case .bassSlide(let pattern, let voice, let index):
      editBass(pattern, voice, index, "Set Slide") { $0 = $0.settingSlide(!$0.slide) }
    case .page(let index):
      page = index
      followsPage = false
    case .perform:
      performing = true
    case .songs:
      if let chip = layout.songChip {
        menuRequest = (songMenu(), SIMD2(chip.frame.x, chip.frame.maxY))
      }
    case .bassStep(let voice, let index):
      select(bass: voice, index)
    case .bassGate(let pattern, let voice, let index):
      editBass(pattern, voice, index, "Set Rest") { $0 = $0.settingGate(!$0.sounds) }
    case .octave(let octave):
      self.octave = min(1, max(0, octave))
    }
  }

  /// On a phone, the 303 step the keyboard sets, with the grid turned to its page and, unless it is
  /// kept, the keyboard to the octave its note is in; nil puts the keyboard away.
  private func select(bass voice: String, _ index: Int?, keepingOctave: Bool = false) {
    guard let index else {
      bassSelection = nil
      return
    }
    bassSelection = (voice, index)
    // The keyboard in place of the knobs' sheet, which there is no room for beside it.
    session.selectedVoice = nil
    showsEffects = false
    page = index / GridMetrics.pageSteps
    followsPage = false
    if !keepingOctave, let note = session.shownPattern?.bassStep(voice, at: index).note.map({ Int($0) }),
      !(octave * 12...octave * 12 + 12).contains(note)
    {
      octave = note > 12 ? 1 : 0
    }
    // Its line scrolled into sight, in the shorter grid the keyboard leaves.
    let layout = layout
    guard let line = layout.bassLines.first(where: { $0.voice == voice }), let rows = layout.gridContent
    else {
      return
    }
    if line.cells.maxY > rows.maxY - 8 {
      scroll = self.layout(scroll: scroll + line.cells.maxY - rows.maxY + 12).scroll
    } else if line.cells.y < rows.y + 8 {
      scroll = self.layout(scroll: scroll - (rows.y - line.cells.y) - 12).scroll
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
    if performing {
      chip(Layout.Chip(frame: editChip, label: "EDIT", action: .perform, isOn: false), on: canvas)
      return
    }
    var layout = layout
    // Paged, the page the playhead is on, while it is followed; and whatever page, one there is.
    if let metrics = layout.metrics, metrics.pages > 1 {
      let wanted =
        followsPage ? layout.playhead.map { $0 / GridMetrics.pageSteps } ?? metrics.page : metrics.page
      if wanted != page {
        page = wanted
        layout = self.layout
      }
    }
    // Kept to what there is, should the window have grown or the pattern shrunk.
    scroll = layout.scroll
    scrollX = layout.scrollX
    held = pressed.flatMap { press in
      hover.flatMap { action(at: $0, in: layout) == press.action ? press.action : nil }
    }
    drawBar(layout, on: canvas)
    drawStrip(layout, on: canvas)
    drawGrid(layout, on: canvas)
    if let inspector = layout.inspector, let song = session.song {
      drawInspector(inspector, song: song, on: canvas)
    }
    if let keyboard = keyboard(in: layout) {
      drawKeyboard(keyboard, on: canvas)
    }
  }

  private func isHovered(_ rect: Rect) -> Bool { hover.map(rect.contains) ?? false }

  /// What is held down and still under the pointer, this frame: what draws as pressed.
  private var held: Action?

  private func isPressed(_ action: Action) -> Bool { held == action }

  private func panel(_ rect: Rect, on canvas: Canvas) { Draw.panel(rect, on: canvas) }

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

    guard let song = session.song else { return }
    canvas.save()
    canvas.clip(layout.readout.x, layout.readout.y, layout.readout.width, layout.readout.height)
    // The tempo and the swing, set by dragging; or, while an outside clock sets the tempo, what it
    // is, in the 303's amber, which is nobody's to drag. For fingers they are in the strip instead.
    let numbers = layout.touch ? [] : layout.numbers
    for number in numbers {
      drawNumber(number, song: song, on: canvas)
    }
    var right = numbers.map(\.cell.x).min() ?? layout.readout.maxX
    if !layout.touch, let followed = session.followedBPM {
      canvas.align = .right
      canvas.font = Theme.mono(14, weight: 600)
      canvas.fill = Theme.three
      let text = KnobSpec.tenths(followed)
      let width = canvas.measure(text)
      canvas.fillText(text, right - 12, baseline + 1)
      canvas.font = Theme.mono(8.5, weight: 500)
      canvas.fill = Theme.dim
      canvas.fillText("EXT", right - 18 - width, baseline)
      right -= 100
    }
    canvas.align = .right
    canvas.font = Theme.mono(11)
    let bar = (session.position?.bar ?? 0) + 1
    let step = (session.position?.step ?? 0) + 1
    canvas.fill = session.isPlaying ? Theme.live : Theme.ink
    canvas.fillText("BAR \(bar)  \(step)/\(layout.pattern?.length ?? 16)", right - 14, baseline)
    canvas.restore()
  }

  /// A number set by dragging it up and down, as a hardware tempo display is set with its data
  /// wheel: its name small, its value large, lit while it is being dragged.
  private func drawNumber(_ number: Layout.Knob, song: Song, on canvas: Canvas) {
    let frame = number.cell
    let dragging = turning?.target == number.target
    let value = dragging ? turning!.value : number.target.value(in: song)
    if dragging || isHovered(frame) {
      canvas.fill = Theme.white(0.07)
      canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 6)
    }
    let baseline = frame.y + frame.height / 2 + 5
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText(number.target.spec.label.uppercased(), frame.x + 7, baseline - 1)
    canvas.align = .right
    canvas.font = Theme.mono(14, weight: 600)
    canvas.fill = dragging ? Theme.nine : Theme.ink.faded(0.9)
    canvas.fillText(number.target.format(value, in: song), frame.maxX - 7, baseline + 1)
  }

  /// A button as the web draws one: a dark rounded chip with a hairline edge that brightens under
  /// the pointer, lit in teal when it is on.
  /// The song's chip: its name, cut to fit with an ellipsis.
  private func drawSongChip(_ chip: Layout.Chip, on canvas: Canvas) {
    canvas.font = Theme.mono(11)
    let room = chip.frame.width - 20
    var name = chip.label
    if canvas.measure(name) > room {
      while !name.isEmpty, canvas.measure(name + "…") > room { name.removeLast() }
      name += "…"
    }
    self.chip(Layout.Chip(frame: chip.frame, label: name, action: chip.action, isOn: false), on: canvas)
  }

  private func chip(_ chip: Layout.Chip, tint: Colour = Theme.nine, on canvas: Canvas) {
    Draw.chip(
      chip.frame, label: chip.label, isOn: chip.isOn, hovered: isHovered(chip.frame),
      down: isPressed(chip.action),
      tint: tint, on: canvas)
  }

  private func drawGrid(_ layout: Layout, on canvas: Canvas) {
    guard let grid = layout.grid, let pattern = layout.pattern, let metrics = layout.metrics else { return }
    panel(grid, on: canvas)
    drawPatternBar(layout, on: canvas)
    guard let rows = layout.gridContent else { return }
    canvas.fill = Theme.edge
    canvas.fillRect(grid.x + 1, rows.y, grid.width - 2, 1)
    canvas.save()
    canvas.clip(grid.x + 1, rows.y + 1, grid.width - 2, rows.height - 2)

    for chip in layout.pageChips {
      self.chip(chip, on: canvas)
    }
    // The ruler: every fourth tick brighter, so a bar reads in beats, and the playhead's tall and lit.
    if let ruler = layout.ruler {
      clipToColumns(layout, on: canvas)
      defer { canvas.restore() }
      for step in metrics.first..<(metrics.first + metrics.shown) {
        let x = ruler.x + Float(step - metrics.first) * metrics.stride
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
      clipToColumns(layout, on: canvas)
      for index in 0..<pattern.length where metrics.shows(index) {
        face(
          layout.step(index, in: lane.frame), value: pattern.step(voice.id, at: index),
          fill: Theme.stepFill(voice.machine), playing: index == layout.playhead, onBeat: index % 4 == 0,
          flam: pattern.flam(voice.id, at: index), tail: index >= loop,
          action: .step(pattern: pattern.id, voice: voice.id, index: index), on: canvas)
      }
      canvas.restore()
    }

    // The pattern-controlled filter's lane, on the drums' columns, in teal.
    if let lane = layout.filterLane {
      canvas.fill = Theme.nine.faded(0.18)
      canvas.fillRect(lane.x + 4, lane.y - 5, lane.width - 8, 1)
      // Beside its steps, or on a phone above them.
      let middle = layout.compact ? lane.y + Layout.nameHeight / 2 : lane.y + lane.height / 2
      canvas.fill = Theme.nine.faded(0.35)
      canvas.fillEllipse(lane.x + 4, middle - 3, 6, 6)
      canvas.font = Theme.mono(11, weight: 500)
      canvas.fill = Theme.nine
      canvas.align = .left
      canvas.fillText("PCF", lane.x + 17, middle + 4)
      clipToColumns(layout, on: canvas)
      for index in 0..<pattern.length where metrics.shows(index) {
        face(
          layout.step(index, in: lane), value: pattern.pcf(at: index), fill: Theme.stepFill(.tr909),
          playing: index == layout.playhead, onBeat: index % 4 == 0, flam: false, tail: false,
          action: .filterStep(pattern: pattern.id, index: index), on: canvas)
      }
      canvas.restore()
    }
    for line in layout.bassLines {
      if layout.touch {
        drawStepBassLine(line, layout, pattern: pattern, metrics: metrics, on: canvas)
      } else {
        drawBassLine(line, layout, pattern: pattern, metrics: metrics, on: canvas)
      }
    }
    canvas.restore()

    // Where the grid is scrolled to, when it is taller than its panel.
    if layout.maxScroll > 0 {
      let track = rows.height - 16
      let thumb = max(24, track * rows.height / (rows.height + layout.maxScroll))
      let top = rows.y + 8 + (track - thumb) * layout.scroll / layout.maxScroll
      canvas.fill = Theme.white(0.18)
      canvas.fillRoundedRect(grid.maxX - 7, top, 3, thumb, radius: 1.5)
    }
    // And sideways, when it is wider.
    if layout.maxScrollX > 0, let columns = layout.columns {
      let track = columns.width
      let thumb = max(24, track * track / (track + layout.maxScrollX))
      let left = columns.x + (track - thumb) * layout.scrollX / layout.maxScrollX
      canvas.fill = Theme.white(0.18)
      canvas.fillRoundedRect(left, grid.maxY - 7, thumb, 3, radius: 1.5)
    }
  }

  /// Only the steps' part of the grid drawn into from here, until the matching `restore`: the steps
  /// scroll under the lanes' names rather than over them.
  private func clipToColumns(_ layout: Layout, on canvas: Canvas) {
    canvas.save()
    if let columns = layout.columns {
      canvas.clip(columns.x - 4, columns.y, columns.width + 8, columns.height)
    }
  }

  /// The keyboard a 303 step's note is set on: the step and its note named, the chips, and the keys,
  /// with the step's own note lit on them while it sounds.
  private func drawKeyboard(_ keyboard: BassKeyboard, on canvas: Canvas) {
    // Solid, unlike the panels over the scene: it is what a finger is on, and nothing shows through.
    let frame = keyboard.frame
    canvas.fill = Theme.panel.opaque
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 12)
    panel(frame, on: canvas)
    let title = keyboard.title
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 600)
    canvas.fill = Theme.three
    canvas.fillText(keyboard.voice == "303.a" ? "303 A" : "303 B", title.x, title.y + 11)
    canvas.font = Theme.mono(13, weight: 600)
    canvas.fill = Theme.ink
    let step = keyboard.step
    let named = step.note.map { BassKeyboard.name(Int($0)) } ?? "—"
    canvas.fillText("STEP \(keyboard.index + 1)  \(step.sounds ? named : "REST")", title.x, title.y + 28)
    for chip in keyboard.chips {
      self.chip(chip, on: canvas)
    }
    let lit = step.sounds ? step.note.map { Int($0) } : nil
    for key in keyboard.keys where !key.black {
      let frame = key.frame
      canvas.fill = key.note == lit ? Colour(0xffde96) : Theme.white(0.82)
      canvas.fillRoundedRect(
        frame.x, frame.y, frame.width, frame.height, radius: 5,
        foot: key.note == lit ? Theme.three : Theme.white(0.6))
      if key.note % 12 == 0 {
        canvas.font = Theme.mono(9, weight: 600)
        canvas.fill = Colour(0x1a1206, alpha: 0.6)
        canvas.align = .center
        canvas.fillText(BassKeyboard.name(key.note), frame.x + frame.width / 2, frame.maxY - 8)
      }
    }
    for key in keyboard.keys where key.black {
      let frame = key.frame
      canvas.fill = key.note == lit ? Theme.three : Colour(0x16161e)
      canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 4)
    }
  }

  /// A 303 line on a phone: a step to a cell, as the machine's own step buttons are, each saying its
  /// note, lit while it sounds and outlined while it is paused, with its accent as an amber foot and
  /// its slide as a violet mark to the right.
  private func drawStepBassLine(
    _ line: Layout.BassLine, _ layout: Layout, pattern: DriftboxSeq.Pattern, metrics: GridMetrics,
    on canvas: Canvas
  ) {
    let selected = session.selectedVoice == line.voice
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 600)
    canvas.fill = Theme.three
    // Above the steps on a phone, beside them on a tablet.
    let baseline = line.header.y + line.header.height / 2 + 3
    canvas.fillText("TB-303", line.header.x, baseline)
    canvas.font = Theme.mono(11, weight: 600)
    canvas.fill = selected ? Theme.ink : Theme.ink.faded(0.8)
    canvas.fillText(line.name, line.header.x + 52, baseline)
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    for index in 0..<pattern.length where metrics.shows(index) {
      let cell = Rect(
        line.cells.x + Float(index - metrics.first) * metrics.stride, line.cells.y, metrics.cell,
        line.cells.height)
      let step = pattern.bassStep(line.voice, at: index)
      let playing = index == layout.playhead
      if let note = step.note.map({ Int($0) }), step.sounds {
        canvas.fill = playing ? Colour(0xffe9b8) : Colour(0xffde96)
        canvas.fillRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 6, foot: Theme.three)
        canvas.fill = Colour(0x1a1206)
        canvas.font = Theme.mono(11, weight: 600)
        canvas.align = .center
        canvas.fillText(
          "\(names[note % 12])\(note / 12 + 1)", cell.x + cell.width / 2, cell.y + cell.height / 2 + 4)
      } else {
        canvas.fill = Theme.white(playing ? 0.14 : index % 4 == 0 ? 0.07 : 0.035)
        canvas.fillRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 6)
        if step.note != nil {
          canvas.stroke = Theme.three.faded(0.55)
          canvas.lineWidth = 1
          canvas.strokeRoundedRect(cell.x, cell.y, cell.width, cell.height, radius: 6)
        }
      }
      if step.accent {
        canvas.fill = Theme.three
        canvas.fillRoundedRect(cell.x + 6, cell.maxY - 5, cell.width - 12, 3, radius: 1.5)
      }
      if step.slide {
        canvas.fill = Theme.violet
        canvas.fillRoundedRect(cell.maxX - 6, cell.y + 6, 3, cell.height - 12, radius: 1.5)
      }
      // The step the keyboard is setting.
      if let selection = bassSelection, selection.voice == line.voice, selection.index == index {
        canvas.stroke = Theme.live
        canvas.lineWidth = 2
        let ring = cell.outset(2)
        canvas.strokeRoundedRect(ring.x, ring.y, ring.width, ring.height, radius: 8)
      }
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
    let right = (layout.columns?.x ?? line.cells.x) - 14
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

    clipToColumns(layout, on: canvas)
    defer { canvas.restore() }
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

  /// The song, drawn to scale: a section per entry of the chain, coloured by pattern so the song's
  /// shape shows — the verse that comes back, the break in the middle. The section the transport is
  /// in lights and fills as it goes, and the loop is a bracket over the bars it covers.
  private func drawStrip(_ layout: Layout, on canvas: Canvas) {
    guard let strip = layout.strip else { return }
    panel(strip, on: canvas)
    canvas.align = .left
    canvas.font = Theme.mono(9, weight: 500)
    canvas.fill = Theme.dim
    if layout.touch {
      // For fingers the head holds the song, as a chip that opens its menu, its length after it,
      // and the tempo and the swing.
      let middle = strip.y + Layout.phoneStripHead / 2 + 3
      if let songChip = layout.songChip {
        drawSongChip(songChip, on: canvas)
      }
      canvas.align = .left
      canvas.font = Theme.mono(9, weight: 500)
      canvas.fill = Theme.dim
      if let song = session.song {
        for number in layout.numbers {
          drawNumber(number, song: song, on: canvas)
        }
        if let followed = session.followedBPM, let swing = layout.numbers.first {
          canvas.align = .right
          canvas.font = Theme.mono(14, weight: 600)
          canvas.fill = Theme.three
          canvas.fillText(KnobSpec.tenths(followed), swing.cell.x - 12, middle + 1)
          canvas.font = Theme.mono(8.5, weight: 500)
          canvas.fill = Theme.dim
          canvas.fillText("EXT", swing.cell.x - 64, middle)
        }
      }
    } else {
      canvas.fillText("SONG", strip.x + 14, strip.y + 17)
      canvas.align = .right
      canvas.fillText("\(layout.totalBars) bars", strip.maxX - 14, strip.y + 17)
    }

    let bar = session.position?.bar ?? -1
    let step = session.position?.step ?? 0
    let length = session.position?.pattern?.length ?? 16
    for section in layout.sections {
      let frame = section.frame
      let tint = Theme.patternColour(section.colour)
      let current = bar >= section.start && bar < section.start + section.bars
      let playing = current && session.isPlaying
      let hovered = isHovered(frame)
      let radius = min(6, frame.width / 2)
      canvas.fill = tint.faded(playing ? 0.28 : hovered ? 0.2 : 0.12)
      canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: radius)
      if playing {
        let progress =
          (Float(bar - section.start) + Float(step) / Float(max(1, length))) / Float(section.bars)
        let width = frame.width * min(1, max(0, progress))
        canvas.fill = tint.faded(0.35)
        canvas.fillRoundedRect(frame.x, frame.y, width, frame.height, radius: min(radius, width / 2))
      }
      if frame.width > 34 {
        canvas.save()
        canvas.clip(frame.x, frame.y, frame.width - 4, frame.height)
        canvas.align = .left
        canvas.font = Theme.mono(10, weight: playing ? 600 : 400)
        canvas.fill = playing ? Theme.ink : Theme.ink.faded(0.75)
        canvas.fillText(section.name, frame.x + 7, frame.y + frame.height / 2 + 4)
        if section.bars > 1, frame.width > 70 {
          canvas.align = .right
          canvas.font = Theme.mono(9)
          canvas.fill = Theme.dim
          canvas.fillText("×\(section.bars)", frame.maxX - 7, frame.y + frame.height / 2 + 4)
        }
        canvas.restore()
      }
      canvas.stroke = tint.faded(playing ? 0.95 : current || hovered ? 0.6 : 0.3)
      canvas.lineWidth = 1
      canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: radius)
      // A dot for each machine playing its own pattern here, in that machine's colour.
      if frame.width > 20 {
        for (index, slot) in section.clips.reversed().enumerated() {
          canvas.fill = Theme.colour(slot)
          canvas.fillEllipse(frame.maxX - 8 - Float(index) * 6, frame.y + 4, 4, 4)
        }
      }
    }
    if let loop = session.loop, let sections = layout.sectionsFrame, layout.totalBars > 0 {
      let from = layout.x(ofBar: loop.start)
      let to = layout.x(ofBar: loop.end, end: true)
      canvas.stroke = Theme.live
      canvas.lineWidth = 2
      canvas.strokeRoundedRect(
        from - 3, sections.y - 3, max(8, to - from + 6), sections.height + 6, radius: 8)
    }
  }

  /// The patterns, at the grid's head: follow the transport, or show one to edit; and add one.
  private func drawPatternBar(_ layout: Layout, on canvas: Canvas) {
    guard let bar = layout.patternBar else { return }
    canvas.align = .left
    canvas.font = Theme.mono(9, weight: 500)
    canvas.fill = Theme.dim
    canvas.fillText("PATTERN", bar.x + 4, bar.y + bar.height / 2 + 3)
    let playing = session.isPlaying ? session.position?.pattern?.id : nil
    for chip in layout.patternChips {
      if case .showPattern(let id) = chip.action, id == renaming?.pattern {
        field(chip, on: canvas)
        continue
      }
      self.chip(chip, on: canvas)
      // The pattern playing, whichever is shown, has a light.
      if case .showPattern(let id) = chip.action, id == playing {
        canvas.fill = Theme.live
        canvas.fillEllipse(chip.frame.maxX - 8, chip.frame.y + 4, 4, 4)
      }
    }
  }

  /// A chip being typed into: sunk rather than raised, edged in teal, its text from the left with a
  /// caret after it.
  private func field(_ chip: Layout.Chip, on canvas: Canvas) {
    let frame = chip.frame
    canvas.fill = Colour(0x000000, alpha: 0.35)
    canvas.fillRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.stroke = Theme.nine
    canvas.lineWidth = 1
    canvas.strokeRoundedRect(frame.x, frame.y, frame.width, frame.height, radius: 7)
    canvas.font = Theme.mono(11)
    canvas.fill = Theme.ink
    canvas.align = .left
    let baseline = frame.y + frame.height / 2 + 4
    canvas.fillText(chip.label, frame.x + 9, baseline)
    canvas.fill = Theme.nine
    canvas.fillRect(frame.x + 9 + canvas.measure(chip.label) + 1, frame.y + 6, 1.5, frame.height - 12)
  }

  /// The selected voice's panel: its machine and name, what can be done with it, its knobs, and
  /// its sends and swing under a line.
  private func drawInspector(_ inspector: Layout.Inspector, song: Song, on canvas: Canvas) {
    let frame = inspector.frame
    panel(frame, on: canvas)
    let tint =
      switch inspector.machine {
      case "TR-808": Theme.eight
      case "TR-909": Theme.nine
      case "TB-303": Theme.three
      default: Theme.violet
      }
    let x = frame.x + Layout.padding
    canvas.align = .left
    canvas.font = Theme.mono(9.5, weight: 600)
    canvas.fill = inspector.voice == nil ? Theme.dim : tint
    canvas.fillText(inspector.machine, x, frame.y + Layout.padding + 9)
    canvas.font = Theme.mono(15, weight: 600)
    canvas.fill = Theme.ink
    canvas.fillText(inspector.title, x, frame.y + Layout.padding + 27)
    for chip in inspector.chips { self.chip(chip, tint: tint, on: canvas) }
    if let divider = inspector.divider {
      canvas.fill = Theme.edge
      canvas.fillRect(x, divider, frame.width - Layout.padding * 2, 1)
    }
    canvas.align = .left
    canvas.font = Theme.mono(8.5, weight: 500)
    canvas.fill = Theme.dim
    for label in inspector.labels { canvas.fillText(label.text, label.x, label.y) }
    for knob in inspector.knobs {
      let value = turning?.target == knob.target ? turning!.value : knob.target.value(in: song)
      let isSend = inspector.voice != nil && knob.dial.width < 40
      drawKnob(
        knob, value: value, label: knob.target.spec.label, text: knob.target.format(value, in: song),
        tint: isSend ? tint.faded(0.8) : tint, active: turning?.target == knob.target, on: canvas)
    }
  }

  /// A knob, as the Mac draws one: a dark cap lit from above, its travel round it with the value
  /// lit in the voice's colour, a pointer, and its name and value underneath.
  private func drawKnob(
    _ knob: Layout.Knob, value: Double, label: String, text: String, tint: Colour, active: Bool,
    on canvas: Canvas
  ) {
    Draw.knob(
      knob.dial, value: value, label: label, text: text, tint: tint, active: active,
      hovered: isHovered(knob.cell), on: canvas)
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
