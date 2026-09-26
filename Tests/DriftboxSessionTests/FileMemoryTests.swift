import DriftboxHost
import DriftboxSession
import Foundation
import Testing

/// What an app remembers in a file of its own, as Android's does: each kind a session keeps, kept
/// from one launch to the next.
@MainActor
struct FileMemoryTests {
  static func file() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("driftbox-memory-\(UUID().uuidString).json")
  }

  @Test func whatIsSetIsThereNextTime() {
    let url = Self.file()
    defer { try? FileManager.default.removeItem(at: url) }
    let memory = FileMemory(url: url)
    #expect(memory.string(forKey: "name") == nil && !memory.bool(forKey: "on"))
    memory.set("acid", forKey: "name")
    memory.set(true, forKey: "on")
    memory.set(Data([1, 2, 3]), forKey: "bytes")
    memory.set(3.5, forKey: "number")

    let again = FileMemory(url: url)
    #expect(again.string(forKey: "name") == "acid")
    #expect(again.bool(forKey: "on") && again.object(forKey: "on") as? Bool == true)
    #expect(again.data(forKey: "bytes") == Data([1, 2, 3]))
    #expect(again.object(forKey: "number") == nil, "what a session never keeps is not kept")

    // A key set again as another kind is that kind only; removed, it is nothing.
    again.set("yes", forKey: "on")
    again.removeObject(forKey: "name")
    again.set(nil, forKey: "bytes")
    let last = FileMemory(url: url)
    #expect(last.string(forKey: "on") == "yes" && !last.bool(forKey: "on"))
    #expect(last.object(forKey: "name") == nil && last.object(forKey: "bytes") == nil)
  }

  @Test func aFileThatCannotBeReadIsNothingRemembered() throws {
    let url = Self.file()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json".utf8).write(to: url)
    let memory = FileMemory(url: url)
    #expect(memory.object(forKey: "anything") == nil)
    memory.set(true, forKey: "on")
    #expect(FileMemory(url: url).bool(forKey: "on"), "and it is written over whole")
  }

  /// A session's settings and its song, kept by one launch and found by the next.
  @Test func aSessionRemembersThroughIt() throws {
    let url = Self.file()
    defer { try? FileManager.default.removeItem(at: url) }
    let first = Session(host: EngineHost(sampleRate: 48000), memory: FileMemory(url: url))
    let entry = try #require(first.entries.first { $0.id == "acid" })
    first.open(entry)
    first.metronome = true
    first.close()

    let next = Session(host: EngineHost(sampleRate: 48000), memory: FileMemory(url: url))
    #expect(next.metronome)
    next.restore()
    #expect(next.current?.id == "acid")
  }
}
