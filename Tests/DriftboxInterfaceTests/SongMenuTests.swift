import DriftboxDocument
import DriftboxEngine
import DriftboxHost
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

  /// A phone with only somewhere to play through, which is the platform's to list.
  final class Outputs: AudioRouting {
    var chosen: String?
    var devices: [AudioDevice]
    var current: AudioDevice?
    var systemDefault: AudioDevice? = AudioDevice(id: "system", name: "the phone's output")
    var error: String?
    var onChange: (() -> Void)?
    var sampleRate: Double { 48000 }
    var latency: Double { 0 }
    init(_ devices: [AudioDevice]) { self.devices = devices }
    func attach(_ source: RenderSource) {}
    func detach(_ context: UnsafeMutableRawPointer) {}
  }

  /// Where the platform lists its outputs, the menu has them: the system's, ticked until one is
  /// chosen, and each device; a device chosen and then unplugged still ticked, as not connected.
  /// Where it lists none, there is nothing to choose and no Output menu.
  @Test func theOutputIsChosenFromTheMenu() throws {
    #expect(!Self.ids(try Self.menu(try Self.touch()).items).contains { $0.hasPrefix("output.") })

    let route = Outputs([
      AudioDevice(id: "speaker::", name: "Speaker"),
      AudioDevice(id: "usb:Scarlett 2i2:", name: "Scarlett 2i2"),
    ])
    let session = Session(host: EngineHost(sampleRate: 48000), audio: route)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-outputs-\(UUID().uuidString).driftbox")
    try Data(SongCodec.encode(InterfaceTests.song()).utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    session.open(file: url)
    let interface = Interface(session: session)
    interface.touch = true
    interface.size = SIMD2(372, 828)
    var menu = try Self.menu(interface)
    #expect(
      Self.ids(menu.items).filter { $0.hasPrefix("output.") }
        == ["output.system", "output.speaker::", "output.usb:Scarlett 2i2:"])
    #expect(interface.menuIsChecked("output.system"))

    interface.choose("output.usb:Scarlett 2i2:")
    #expect(session.outputDevice == "usb:Scarlett 2i2:" && route.chosen == "usb:Scarlett 2i2:")
    menu = try Self.menu(interface)
    #expect(interface.menuIsChecked("output.usb:Scarlett 2i2:") && !interface.menuIsChecked("output.system"))

    // Unplugged: still the choice, and saying so.
    route.devices.removeLast()
    route.onChange?()
    menu = try Self.menu(interface)
    let output = try #require(
      menu.items.compactMap { item -> Menu? in
        if case .submenu(let sub) = item, sub.title == "Output" { sub } else { nil }
      }
      .first)
    #expect(output.commands.last?.title == "Scarlett 2i2 (Not Connected)")
    #expect(interface.menuIsChecked("output.missing") && !interface.menuIsEnabled("output.missing"))

    interface.choose("output.system")
    #expect(session.outputDevice == nil)
  }
}
