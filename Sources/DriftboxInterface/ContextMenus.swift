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
    guard isShowing, let song = session.song else { return nil }
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

  // MARK: - The menus

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

  /// Chance, for randomising and altering: the system's, since what comes out is not meant to be
  /// the same twice.
  static func chance() -> Double { Double.random(in: 0..<1) }
}
