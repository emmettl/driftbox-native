#if os(Windows)
  import DriftboxHostVST3
  import Foundation
  import Testing

  /// The scanner: each module that does not describe itself asked in a process of its own, so one
  /// that crashes as it loads, or takes too long, holds nothing rather than taking the host with
  /// it; and what each held remembered, until it changes.
  struct VST3ScannerTests {
    /// A folder of modules: the test plug-in, one that crashes as it loads, and one that is no
    /// module at all.
    static func folder() throws -> URL {
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("driftbox-scan-\(UUID().uuidString)")
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      try files.copyItem(
        at: URL(fileURLWithPath: VST3BridgeTests.bundle),
        to: root.appendingPathComponent("Driftbox Test.vst3"))
      let build = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      try files.copyItem(
        at: build.appendingPathComponent("DriftboxVST3Crash.dll"),
        to: root.appendingPathComponent("Crash.vst3"))
      try Data("not a module".utf8).write(to: root.appendingPathComponent("Broken.vst3"))
      return root
    }

    static let nowhere = URL(fileURLWithPath: "C:/nowhere/DriftboxVST3Scan.exe")

    /// The test plug-in's classes are found by the scanner, and the module that crashes and the one
    /// that is none hold nothing, and this is still here to say so. Asked again, what each held is
    /// remembered, with no scanner to ask; a module that has changed is asked again; and one that
    /// has gone is forgotten.
    @Test func aModuleThatCrashesHoldsNothing() throws {
      let folder = try Self.folder()
      defer { try? FileManager.default.removeItem(at: folder) }
      var scanner = VST3Scanner()
      #expect(scanner.program != nil, "the scanner, built beside the tests")
      let catalogue = VST3Catalogue.scan([folder], with: &scanner)
      #expect(catalogue.entries.map(\.reference.name) == ["Driftbox Test Gain", "Driftbox Test Synth"])
      let crash = folder.appendingPathComponent("Crash.vst3").path
      let broken = folder.appendingPathComponent("Broken.vst3").path
      #expect(scanner.known.count == 3)
      #expect(scanner.known[crash]?.classes == [] && scanner.known[broken]?.classes == [])

      var remembered = VST3Scanner(program: Self.nowhere, known: scanner.known)
      #expect(VST3Catalogue.scan([folder], with: &remembered).entries == catalogue.entries)

      let binary = folder.appendingPathComponent("Driftbox Test.vst3/Contents/x86_64-win/Driftbox Test.vst3")
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: binary.path)
      #expect(
        VST3Catalogue.scan([folder], with: &remembered).entries.isEmpty, "changed, so asked, and no answer")

      try FileManager.default.removeItem(atPath: broken)
      _ = VST3Catalogue.scan([folder], with: &remembered)
      #expect(remembered.known[broken] == nil && remembered.known[crash] != nil)
    }

    /// A module that does not answer in time holds nothing.
    @Test func aModuleThatTakesTooLongHoldsNothing() throws {
      let folder = try Self.folder()
      defer { try? FileManager.default.removeItem(at: folder) }
      var scanner = VST3Scanner(timeout: 0)
      #expect(VST3Catalogue.scan([folder], with: &scanner).entries.isEmpty)
      #expect(scanner.known[folder.appendingPathComponent("Driftbox Test.vst3").path]?.classes == [])
    }

    /// What the scanner was told is kept from one launch to the next: a host made again, with no
    /// scanner to ask, still finds the plug-ins.
    @MainActor
    @Test func whatWasFoundIsKeptFromOneLaunchToTheNext() async throws {
      let folder = try Self.folder()
      defer { try? FileManager.default.removeItem(at: folder) }
      let suite = "driftbox-scan-\(UUID().uuidString)"
      let memory = try #require(UserDefaults(suiteName: suite))
      defer { memory.removePersistentDomain(forName: suite) }

      let first = await VST3Hosting(folders: [folder], memory: memory).available()
      #expect(first.map(\.reference.name) == ["Driftbox Test Gain", "Driftbox Test Synth"])
      #expect(memory.data(forKey: "vst3.scanned") != nil)
      let later = VST3Hosting(folders: [folder], scanner: VST3Scanner(program: Self.nowhere), memory: memory)
      let again = await later.available()
      #expect(again == first)
    }
  }
#endif
