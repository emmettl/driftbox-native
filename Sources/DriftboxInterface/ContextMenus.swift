import DriftboxHelp
import DriftboxSeq
import DriftboxSession
import DriftboxShell

/// What a secondary press offers, as the Mac's lane, line and section menus do: the menu for what is
/// under the pointer, made as data for the platform to show as its own, with what each command does
/// kept here until one is chosen.
extension Interface {
  /// The menu for what is at `point`, or nil if nothing there has one: a drum lane, a 303 line, a
  /// section of the song, or a pattern's chip.
  public func menu(at point: SIMD2<Float>) -> Menu? {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
    guard guide == nil, isShowing, let song = session.song else { return nil }
    let layout = layout
    if let section = layout.sections.first(where: { $0.frame.contains(point) }) {
      return sectionMenu(section, song: song)
    }
    if let chip = layout.patternChips.first(where: { $0.frame.contains(point) }),
      case .showPattern(let id) = chip.action
    {
      return patternMenu(id, song: song)
    }
    guard let rows = layout.gridContent, rows.contains(point), let pattern = layout.pattern else {
      return nil
    }
    if let lane = layout.lanes.first(where: { $0.frame.contains(point) }) {
      return laneMenu(lane.voice.id, name: lane.voice.name, pattern: pattern)
    }
    if let line = layout.bassLines.first(where: { $0.frame.contains(point) }) {
      return lineMenu(line.voice, name: line.name, pattern: pattern)
    }
    return nil
  }

  /// Whether a command of the menu last made can be chosen.
  public func menuIsEnabled(_ id: String) -> Bool { !menuDisabled.contains(id) }
  /// Whether it shows as on.
  public func menuIsChecked(_ id: String) -> Bool { menuChecked.contains(id) }

  /// Do what a command of the menu last made does.
  public func choose(_ id: String) {
    guard menuIsEnabled(id), let action = menuActions[id] else { return }
    menuActions = [:]
    action()
  }

  /// A menu a tap asked for, once: the platform shows it as its own, and `choose` does what is
  /// chosen from it.
  public func takeMenuRequest() -> (menu: Menu, at: SIMD2<Float>)? {
    defer { menuRequest = nil }
    return menuRequest
  }

  // MARK: - The menus

  /// The song's: its file, where the platform can open and save one, and the catalogue's songs.
  func songMenu() -> Menu {
    menuActions = [:]
    menuDisabled = []
    menuChecked = []
    var items: [MenuItem] = []
    if let showRack {
      menuActions["rack.show"] = showRack
      items += [.command("Rack", id: "rack.show"), .separator]
    }
    if let files {
      menuActions["file.open"] = { [weak self] in self?.unlessEdited { files(.open) } }
      menuActions["file.save"] = { files(.save) }
      menuActions["file.saveAs"] = { files(.saveAs) }
      if session.song == nil {
        menuDisabled.formUnion(["file.save", "file.saveAs"])
      }
      items += [
        .command("Open…", id: "file.open"), .command("Save", id: "file.save"),
        .command("Save As…", id: "file.saveAs"), .separator,
      ]
    }
    // Where the sound goes, on a touchscreen, whose only menu this is; a desktop has its Audio menu.
    if touch, !session.outputs.isEmpty || session.outputDevice != nil {
      items.append(.submenu(outputMenu()))
    }
    let songs = session.entries.map { entry -> MenuItem in
      let id = "song." + entry.id
      menuActions[id] = { [weak self] in self?.unlessEdited { self?.session.open(entry) } }
      if session.current?.id == entry.id { menuChecked.insert(id) }
      return .command(entry.name, id: id)
    }
    items.append(.submenu(Menu("Songs", songs)))
    if let helpGuide {
      menuActions["help.groovebox"] = { [weak self] in
        guard let self else { return }
        let sheet = HelpSheet(guide: helpGuide)
        sheet.size = size
        guide = sheet
      }
      items += [.separator, .command("Groovebox Guide", id: "help.groovebox")]
    }
    return Menu(session.song == nil ? "Driftbox" : session.documentName, items)
  }

  /// Automatic, as the platform routes it, or a device; and a device chosen and not plugged in,
  /// which is still the choice and says so, as the desktop's Audio menu does.
  private func outputMenu() -> Menu {
    menuActions["output.automatic"] = { [weak self] in self?.session.outputDevice = nil }
    if session.outputDevice == nil { menuChecked.insert("output.automatic") }
    var items: [MenuItem] = [.command("Automatic", id: "output.automatic"), .separator]
    for device in session.outputs {
      let id = "output." + device.id
      menuActions[id] = { [weak self] in self?.session.outputDevice = device.id }
      if session.outputDevice == device.id { menuChecked.insert(id) }
      items.append(.command(device.name, id: id))
    }
    if let chosen = session.outputDevice, !session.outputs.contains(where: { $0.id == chosen }) {
      let id = "output." + chosen
      menuChecked.insert(id)
      menuDisabled.insert(id)
      items.append(.command("\(session.outputDeviceName ?? "A Device") (Not Connected)", id: id))
    }
    if let error = session.outputError {
      menuDisabled.insert("output.note")
      items.append(.command(error, id: "output.note"))
    }
    return Menu("Output", items)
  }

  /// `then`, once the platform has said to go on if the song has edits that are not saved.
  private func unlessEdited(_ then: @escaping () -> Void) {
    guard session.isEdited, let confirm else { return then() }
    confirm("\(session.documentName) has changes that are not saved. Lose them?", then)
  }

  private func laneMenu(_ voice: String, name: String, pattern: DriftboxSeq.Pattern) -> Menu {
    let id = pattern.id
    let lengths = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32].filter { $0 <= pattern.length }
    return Menu(
      name,
      [
        item("Rotate Left", "lane.rotateLeft") {
          self.editPattern(id, "Rotate Left") { $0.rotatingTrack(voice, by: -1) }
        },
        item("Rotate Right", "lane.rotateRight") {
          self.editPattern(id, "Rotate Right") { $0.rotatingTrack(voice, by: 1) }
        },
        item("Randomise", "lane.randomise") {
          self.editPattern(id, "Randomise") { $0.randomisingTrack(voice, random: Self.chance) }
        },
        item("Alter", "lane.alter") {
          self.editPattern(id, "Alter") { $0.alteringTrack(voice, random: Self.chance) }
        },
        item("Clear", "lane.clear") { self.editPattern(id, "Clear Lane") { $0.clearingTrack(voice) } },
        .separator,
        item("Copy Lane", "lane.copy") { self.session.copyLane(voice) },
        item("Cut Lane", "lane.cut") { self.session.cutLane(voice) },
        item("Paste Lane", "lane.paste", enabled: session.canPasteLane(into: voice)) {
          self.session.pasteLane(into: voice)
        },
        .separator,
        .submenu(
          Menu(
            "Loop Length",
            lengths.map { length in
              item(
                length == pattern.length ? "\(length) (full)" : "\(length)", "lane.length.\(length)",
                checked: pattern.trackLength(voice) == length
              ) { self.editPattern(id, "Set Loop Length") { $0.settingTrackLength(voice, to: length) } }
            })),
      ])
  }

  private func lineMenu(_ voice: String, name: String, pattern: DriftboxSeq.Pattern) -> Menu {
    let id = pattern.id
    func transpose(_ title: String, _ command: String, by semitones: Int) -> MenuItem {
      item(title, command) {
        self.editPattern(id, "Transpose") { $0.transposingBassLine(voice, by: semitones) }
      }
    }
    return Menu(
      name,
      [
        item("Rotate Left", "line.rotateLeft") {
          self.editPattern(id, "Rotate Left") { $0.rotatingBassLine(voice, by: -1) }
        },
        item("Rotate Right", "line.rotateRight") {
          self.editPattern(id, "Rotate Right") { $0.rotatingBassLine(voice, by: 1) }
        },
        transpose("Up an Octave", "line.octaveUp", by: 12),
        transpose("Down an Octave", "line.octaveDown", by: -12),
        transpose("Up a Semitone", "line.semitoneUp", by: 1),
        transpose("Down a Semitone", "line.semitoneDown", by: -1),
        item("Randomise", "line.randomise") {
          self.editPattern(id, "Randomise") { $0.randomisingBassLine(voice, random: Self.chance) }
        },
        item("Alter", "line.alter") {
          self.editPattern(id, "Alter") { $0.alteringBassLine(voice, random: Self.chance) }
        },
        item("Clear", "line.clear") { self.editPattern(id, "Clear Line") { $0.clearingBassLine(voice) } },
        .separator,
        item("Copy Line", "line.copy") { self.session.copyLane(voice) },
        item("Cut Line", "line.cut") { self.session.cutLane(voice) },
        item("Paste Line", "line.paste", enabled: session.canPasteLane(into: voice)) {
          self.session.pasteLane(into: voice)
        },
      ])
  }

  private func sectionMenu(_ section: Layout.Section, song: Song) -> Menu {
    let index = section.index
    let entry = song.chain[index]
    let looped = session.loop == Session.LoopRange(start: section.start, bars: section.bars)
    var items: [MenuItem] = [
      item("Play from Here", "section.play") { self.session.seek(toBar: section.start) },
      item(looped ? "Stop Looping This Section" : "Loop This Section", "section.loop") {
        self.session.toggleLoop(start: section.start, bars: section.bars)
      },
    ]
    if let loop = session.loop, !looped {
      items.append(
        item("Stretch Loop to Here", "section.stretch") {
          self.session.extendLoop(toStart: section.start, bars: section.bars)
        })
      items.append(
        item("Clear Loop (Bars \(loop.start + 1)–\(loop.end))", "section.clearLoop") {
          self.session.loop = nil
        })
    }
    items += [
      .separator,
      .submenu(
        Menu(
          "Pattern",
          song.patterns.map { pattern in
            item(pattern.name, "section.pattern.\(pattern.id)", checked: entry.pattern == pattern.id) {
              self.session.edit("Set Section Pattern") {
                $0 = $0.settingChainPattern(at: index, to: pattern.id)
              }
            }
          })),
      // One machine playing something else for a section — the 303 carrying on while the drums
      // change underneath it.
      .submenu(
        Menu(
          "Machines",
          ClipSlot.allCases.map { slot in
            let chosen = entry.clips[slot] ?? entry.pattern
            return .submenu(
              Menu(
                Self.title(of: slot),
                song.patterns.map { pattern in
                  item(
                    pattern.id == entry.pattern ? "\(pattern.name) (the section's)" : pattern.name,
                    "section.clip.\(slot.rawValue).\(pattern.id)", checked: chosen == pattern.id
                  ) {
                    self.session.edit("Set \(Self.title(of: slot)) Pattern") {
                      $0 = $0.settingChainClip(at: index, slot: slot, to: pattern.id)
                    }
                  }
                }))
          })),
      .submenu(
        Menu(
          "Repeat",
          [1, 2, 3, 4, 6, 8, 12, 16, 24, 32].map { bars in
            item(
              "\(bars) bar\(bars == 1 ? "" : "s")", "section.repeat.\(bars)",
              checked: max(1, entry.repeat) == bars
            ) {
              self.session.edit("Set Repeat") { $0 = $0.settingChainRepeat(at: index, to: bars) }
            }
          })),
      .separator,
      item("Move Earlier", "section.earlier", enabled: index > 0) {
        self.session.edit("Move Section") { $0 = $0.movingChainEntry(at: index, by: -1) }
      },
      item("Move Later", "section.later", enabled: index < song.chain.count - 1) {
        self.session.edit("Move Section") { $0 = $0.movingChainEntry(at: index, by: 1) }
      },
      .separator,
      item("Remove from Song", "section.remove", enabled: song.chain.count > 1) {
        self.session.edit("Remove Section") { $0 = $0.removingFromChain(at: index) }
      },
    ]
    return Menu(section.name, items)
  }

  private func patternMenu(_ id: String, song: Song) -> Menu {
    let name = song.pattern(id: id)?.name ?? id
    return Menu(
      name,
      [
        item("Rename…", "pattern.rename") { self.rename(pattern: id) },
        item("Add to Song", "pattern.addToSong") {
          self.session.edit("Add to Song") { $0 = $0.appendingToChain(id) }
        },
        item("Duplicate", "pattern.duplicate") {
          var made: String?
          self.session.edit("Duplicate Pattern") { song in
            let result = song.duplicatingPattern(id)
            song = result.song
            made = result.id
          }
          if let made { self.session.editing = made }
        },
        .separator,
        item("Remove", "pattern.remove", enabled: song.patterns.count > 1) {
          if self.session.editing == id { self.session.editing = nil }
          self.session.edit("Remove Pattern") { $0 = $0.removingPattern(id) }
        },
      ])
  }

  // MARK: - Making them

  /// A command, kept with what it does and whether it is greyed or ticked.
  private func item(
    _ title: String, _ id: String, enabled: Bool = true, checked: Bool = false, _ action: @escaping () -> Void
  ) -> MenuItem {
    menuActions[id] = action
    if !enabled { menuDisabled.insert(id) }
    if checked { menuChecked.insert(id) }
    return .command(title, id: id)
  }

  private func editPattern(
    _ id: String, _ name: String, _ change: (DriftboxSeq.Pattern) -> DriftboxSeq.Pattern
  ) {
    session.editPattern(id, name, change)
  }

  /// A machine, as its menu names it.
  static func title(of slot: ClipSlot) -> String {
    switch slot {
    case .tr808: "TR-808"
    case .tr909: "TR-909"
    case .bassA: "303 A"
    case .bassB: "303 B"
    }
  }

  /// Chance, for randomising and altering: the system's, since what comes out is not meant to be
  /// the same twice.
  static func chance() -> Double { Double.random(in: 0..<1) }
}

// MARK: - Renaming

extension Interface {
  /// Start renaming a pattern: its chip becomes a field holding its name, typed into from here.
  public func rename(pattern id: String) {
    guard let pattern = session.song?.pattern(id: id) else { return }
    renaming = (id, pattern.name)
  }

  /// A key, while a name is being typed: a character to add, Backspace to take one away, Return to
  /// keep the name and Escape to leave it as it was. Every key is the name's while it is; false
  /// when nothing is being named.
  public func key(_ event: KeyEvent) -> Bool {
    // A guide has every key, and Escape closes it.
    if let guide {
      _ = guide.key(event)
      if !guide.isOpen { self.guide = nil }
      return true
    }
    guard var renaming else { return false }
    guard event.isDown else { return true }
    switch event.key {
    case .return:
      finishRenaming()
      return true
    case .escape:
      self.renaming = nil
      return true
    case .backspace:
      if !renaming.text.isEmpty { renaming.text.removeLast() }
    case .space:
      renaming.text.append(" ")
    case .character(let character) where event.modifiers.isSubset(of: [.shift]):
      renaming.text.append(character)
    default:
      return true
    }
    renaming.text = String(renaming.text.prefix(Self.longestName))
    self.renaming = renaming
    return true
  }

  /// The longest a pattern's name may be typed.
  public static let longestName = 24

  /// Keep the name typed: an empty one, or one only of spaces, is not kept, as the song's own
  /// renaming has it.
  func finishRenaming() {
    guard let renaming else { return }
    self.renaming = nil
    guard session.song?.pattern(id: renaming.pattern)?.name != renaming.text else { return }
    session.edit("Rename Pattern") { $0 = $0.renamingPattern(renaming.pattern, to: renaming.text) }
  }
}
