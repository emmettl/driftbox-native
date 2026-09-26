import DriftboxEngine
import DriftboxHost
import DriftboxInterface
import DriftboxSeq
import DriftboxSession
import DriftboxShell
import Testing

/// On a touchscreen, where the song's menu is the only menu, it says where the sound goes: as the
/// platform routes it, or a device of the platform's, and a device chosen and unplugged as such.
@MainActor
struct OutputMenuTests {
  final class Outputs: AudioRouting {
    var chosen: String?
    var devices: [AudioDevice] = []
    var current: AudioDevice?
    var systemDefault: AudioDevice?
    var error: String?
    var onChange: (() -> Void)?
    var sampleRate: Double { 48000 }
    var latency: Double { 0 }
    func attach(_ source: RenderSource) {}
    func detach(_ context: UnsafeMutableRawPointer) {}
  }

  static let speaker = AudioDevice(id: "speaker:Phone", name: "Speaker")
  static let box = AudioDevice(id: "usb:Box", name: "Box")

  static func output(of interface: Interface) throws -> Menu {
    interface.perform(.songs)
    let menu = try #require(interface.takeMenuRequest()).menu
    let found = menu.items.compactMap { item -> Menu? in
      if case .submenu(let sub) = item, sub.title == "Output" { sub } else { nil }
    }
    return try #require(found.first)
  }

  static func titles(_ menu: Menu) -> [String] {
    menu.items.compactMap { if case .command(let command) = $0 { command.title } else { nil } }
  }

  @Test func aTouchscreenChoosesWhereTheSoundGoes() throws {
    let route = Outputs()
    route.devices = [Self.speaker, Self.box]
    let session = Session(host: EngineHost(sampleRate: 48000), audio: route)
    session.open(InterfaceTests.song(), named: "Test")
    let interface = Interface(session: session)
    interface.touch = true
    interface.size = SIMD2(372, 828)

    var menu = try Self.output(of: interface)
    #expect(Self.titles(menu) == ["Automatic", "Speaker", "Box"])
    #expect(interface.menuIsChecked("output.automatic"))
    interface.choose("output.usb:Box")
    #expect(session.outputDevice == "usb:Box" && route.chosen == "usb:Box")

    // Unplugged, it is still the choice, and says so, greyed; Automatic puts it away.
    route.devices = [Self.speaker]
    route.onChange?()
    menu = try Self.output(of: interface)
    #expect(Self.titles(menu) == ["Automatic", "Speaker", "Box (Not Connected)"])
    #expect(interface.menuIsChecked("output.usb:Box") && !interface.menuIsEnabled("output.usb:Box"))
    interface.choose("output.automatic")
    #expect(session.outputDevice == nil && route.chosen == nil)

    // A desktop has its Audio menu for it.
    interface.touch = false
    interface.size = SIMD2(800, 600)
    interface.perform(.songs)
    if let desktop = interface.takeMenuRequest()?.menu {
      let hasOutput = desktop.items.contains {
        if case .submenu(let sub) = $0 { sub.title == "Output" } else { false }
      }
      #expect(!hasOutput)
    }
  }
}
