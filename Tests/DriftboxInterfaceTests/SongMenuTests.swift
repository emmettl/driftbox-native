import DriftboxDocument
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Foundation
import Testing

/// On a touchscreen the song's name heads the strip, and a tap on it is the song's menu: its file,
/// opened and saved through the platform's own pickers, and the catalogue's songs; with a question
/// first, where the platform can ask one, before edits are lost.
@MainActor
struct SongMenuTests {
  static func touch(_ size: SIMD2<Float> = SIMD2(372, 828)) throws -> Interface {
    let interface = try InterfaceTests.interface()
    interface.touch = true
    interface.size = size
    return interface
  }

  static func menu(_ interface: Interface) throws -> Menu {
    let chip = try #require(interface.layout.songChip)
    TabletLayoutTests.tap(interface, chip.frame)
    return try #require(interface.takeMenuRequest()?.menu)
  }

  static func ids(_ items: [MenuItem]) -> [String] {
    items.flatMap { item -> [String] in
      switch item {
      case .command(let command): [command.id]
      case .submenu(let menu): ids(menu.items)
      case .separator: []
      }
    }
  }

  @Test(arguments: [SIMD2<Float>(372, 828), SIMD2<Float>(800, 1280)])
  func theSongsNameHeadsTheStrip(size: SIMD2<Float>) throws {
    let interface = try Self.touch(size)
    let layout = interface.layout
    let chip = try #require(layout.songChip)
    let strip = try #require(layout.strip)
    #expect(chip.label == interface.session.documentName)
    #expect(strip.contains(InterfaceTests.centre(chip.frame)), "in the strip's head")
    #expect(chip.frame.height >= 30, "a finger's height")
    #expect(layout.numbers.allSatisfy { chip.frame.maxX <= $0.cell.x }, "clear of the tempo and swing")
    // A window has its menu bar, and no chip.
    let window = try InterfaceTests.interface()
    #expect(window.layout.songChip == nil)
  }

  @Test func aTapIsTheSongsMenu() throws {
    let interface = try Self.touch()
    var asked: [Interface.FileAction] = []
    interface.files = { asked.append($0) }
    let menu = try Self.menu(interface)
    let ids = Self.ids(menu.items)
    #expect(ids.prefix(3) == ["file.open", "file.save", "file.saveAs"])
    #expect(ids.count == 3 + interface.session.entries.count, "and every song of the catalogue")
    interface.choose("file.saveAs")
    _ = try Self.menu(interface)
    interface.choose("file.save")
    _ = try Self.menu(interface)
    interface.choose("file.open")
    #expect(asked == [.saveAs, .save, .open])
  }

  /// Without a platform that can open and save, the menu is the catalogue's songs alone.
  @Test func noPlatformNoFiles() throws {
    let interface = try Self.touch()
    let ids = Self.ids(try Self.menu(interface).items)
    #expect(!ids.contains { $0.hasPrefix("file.") })
    let entry = try #require(interface.session.entries.first)
    interface.choose("song." + entry.id)
    #expect(interface.session.current?.id == entry.id)
  }

  /// Edits not saved are lost only once the platform has asked, and been told to go on.
  @Test func editsAreLostOnlyWhenSaidTo() throws {
    let interface = try Self.touch()
    let session = interface.session
    var questions: [String] = []
    var goOn: (() -> Void)?
    interface.confirm = { question, then in
      questions.append(question)
      goOn = then
    }
    let before = session.current?.id
    let entry = try #require(session.entries.first { $0.id != before })
    session.edit { $0.bpm = 97 }
    #expect(session.isEdited)
    _ = try Self.menu(interface)
    interface.choose("song." + entry.id)
    #expect(questions.count == 1 && session.current?.id == before, "asked, and nothing lost yet")
    goOn?()
    #expect(session.current?.id == entry.id)

    // Nothing to lose, nothing asked.
    let other = try #require(session.entries.first { $0.id != entry.id })
    _ = try Self.menu(interface)
    interface.choose("song." + other.id)
    #expect(questions.count == 1 && session.current?.id == other.id)
  }
}
