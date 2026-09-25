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
