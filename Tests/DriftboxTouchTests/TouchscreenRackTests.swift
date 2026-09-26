import DriftboxGPU
import DriftboxHost
import DriftboxInterface
import DriftboxRack
import DriftboxRackSession
import DriftboxSession
import DriftboxShell
import Foundation
import Testing

@testable import DriftboxTouch

/// The rack on a touch screen: shown from the song's menu, and a module asking for recordings asking
/// the platform, whose picker's choice is loaded into it.
@MainActor
struct TouchscreenRackTests {
  /// A phone's screen with a rack beside the groovebox: an empty Slice Lab, and an Out.
  static func screen() throws -> (Touchscreen, RackSession)? {
    guard let screen = try TouchscreenTests.screen() else { return nil }
    let rack = RackSession()
    rack.open(
      Patch(
        modules: [PatchModule(id: "m", type: "sampler"), PatchModule(id: "out", type: "out")], cables: []),
      name: "Samples")
    screen.add(rack)
    return (screen, rack)
  }

  @Test func theSongsMenuShowsTheRack() throws {
    guard let (screen, _) = try Self.screen() else { return }
    let chip = try #require(screen.interface.layout.songChip)
    let at = SIMD2(chip.frame.x + chip.frame.width / 2, chip.frame.y + chip.frame.height / 2)
    var shown: Menu?
    screen.onMenu = { menu, _ in shown = menu }
    screen.touch(TouchscreenTests.finger(.began, 1, at))
    screen.touch(TouchscreenTests.finger(.ended, 1, at))
    #expect(shown != nil)
    screen.choose("rack.show")
    #expect(screen.showsRack)
  }

  /// A Slice Lab's prompt, tapped, asks the platform for a recording; what its picker chooses loads.
  @Test func aModuleAsksThePlatformForRecordings() async throws {
    guard let (screen, rack) = try Self.screen(), let face = screen.rack else { return }
    screen.show(rack: true)
    face.size = SIMD2(372, 828)
    let stage = face.stage
    let lab = try #require(stage.faces.first { $0.module.id == "m" })
    let prompt = try #require(lab.buttons.first { if case .prompt = $0.style { true } else { false } })
    let at =
      stage.origin + SIMD2(prompt.frame.x + prompt.frame.width / 2, prompt.frame.y + prompt.frame.height / 2)
      * stage.scale
    var asked: (module: String, several: Bool)?
    screen.onFiles = { asked = ($0, $1) }
    screen.touch(TouchscreenTests.finger(.began, 1, at))
    screen.touch(TouchscreenTests.finger(.ended, 1, at))
    #expect(asked?.module == "m" && asked?.several == false)

    #expect(screen.load([try Self.wav()], into: "m"))
    for _ in 0..<300 where rack.samples["m"] == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(rack.samples["m"] != nil, "the recording in it")
  }

  /// A finger on the rack at `at`, in points on the screen, down and lifted.
  static func tap(_ screen: Touchscreen, _ at: SIMD2<Float>) {
    screen.touch(TouchscreenTests.finger(.began, 1, at))
    screen.touch(TouchscreenTests.finger(.ended, 1, at))
  }

  /// A groovebox song in the rack: its face's Edit in Groovebox, tapped, links it into the
  /// groovebox and shows the groovebox in the rack's place, once unsaved edits there are let go
  /// of; each edit there plays on in the rack.
  @Test func aRackSongIsEditedInTheGroovebox() throws {
    guard let (screen, rack) = try Self.screen(), let face = screen.rack else { return }
    let song = try #require(Catalogue.song("acid"))
    rack.openSong(song, name: "Acid in the Rack")
    screen.session.edit("Rename Pattern") { $0 = $0.renamingPattern($0.patterns[0].id, to: "Unsaved") }
    var asked: (() -> Void)?
    screen.interface.confirm = { _, then in asked = then }
    screen.show(rack: true)
    face.size = SIMD2(372, 828)
    let stage = face.stage
    let groovebox = try #require(stage.faces.first { $0.module.type == "groovebox" })
    let edit = try #require(groovebox.buttons.first { $0.press == .editSong })
    let at =
      stage.origin + SIMD2(edit.frame.x + edit.frame.width / 2, edit.frame.y + edit.frame.height / 2)
      * stage.scale

    Self.tap(screen, at)
    #expect(screen.showsRack && !screen.session.linkedToRack, "not until the unsaved edits may go")
    let then = try #require(asked)
    then()
    #expect(!screen.showsRack && screen.session.linkedToRack && rack.songLinked)
    #expect(screen.session.song == rack.song && screen.session.documentName == "Acid in the Rack")

    screen.interface.rename(pattern: song.patterns[0].id, to: "Edited Here")
    #expect(rack.song?.pattern(id: song.patterns[0].id)?.name == "Edited Here", "and plays on in the rack")

    rack.open(PatchEntry.all[0])
    #expect(!screen.session.linkedToRack, "another patch lets it go")
  }

  /// The rack's patch menu offers the groovebox's songs: the one open there and the catalogue's.
  @Test func thePatchMenuOffersGrooveboxSongs() throws {
    guard let (screen, rack) = try Self.screen(), let face = screen.rack else { return }
    screen.show(rack: true)
    face.size = SIMD2(372, 828)
    let chip = try #require(face.stage.chips.first { $0.target == .patches })
    var shown: Menu?
    screen.onMenu = { menu, _ in shown = menu }
    Self.tap(screen, SIMD2(chip.frame.x + chip.frame.width / 2, chip.frame.y + chip.frame.height / 2))
    let songs = try #require(
      shown?.items.lazy.compactMap {
        if case .submenu(let menu) = $0, menu.title == "Groovebox Songs" { menu } else { nil }
      }
      .first)
    let ids = songs.items.compactMap { if case .command(let c) = $0 { c.id } else { nil } }
    #expect(ids.first == "rackSong.groovebox" && ids.contains("rackSong.acid"))

    screen.choose("rackSong.groovebox")
    #expect(rack.song == screen.session.song && rack.name == screen.session.documentName)
    #expect(rack.patch.modules.contains { $0.type == "groovebox" })
  }

  /// A second of a sine at 48 kHz, as a WAV.
  static func wav() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    var body = Data()
    for i in 0..<48000 {
      let value = Int16(12000 * sin(2 * Double.pi * 220 * Double(i) / 48000))
      withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) }
    }
    var file = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
    file.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + body.count))
    file.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(48000)
    u32(96000)
    u16(2)
    u16(16)
    file.append(contentsOf: Array("data".utf8))
    u32(UInt32(body.count))
    file.append(body)
    try file.write(to: url)
    return url
  }
}
