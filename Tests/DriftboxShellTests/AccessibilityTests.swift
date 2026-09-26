#if os(Windows)
  import DriftboxShell
  import Foundation
  import Testing
  import WinSDK

  @testable import DriftboxWin32

  /// A window's drawn controls as a screen reader reads them: through Windows' own UI Automation, from
  /// a process of its own as Narrator and NVDA are — `DriftboxAXProbe`, built beside the tests. Their
  /// roles, names, states and values, where they sit under one another, and what a screen reader asks
  /// of them arriving as the window's events, on its own thread.
  @MainActor
  struct AccessibilityTests {
    static let probe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      .appendingPathComponent("DriftboxAXProbe.exe")

    /// The probe run against `window`, while this thread takes the window's messages — which is how UI
    /// Automation reaches it: what it wrote, and whether it did what it was asked.
    static func run(_ window: Win32Window, _ arguments: String...) throws -> (text: String, done: Bool) {
      let output = FileManager.default.temporaryDirectory.appendingPathComponent(
        "driftbox-ax-\(UUID().uuidString)")
      _ = FileManager.default.createFile(atPath: output.path, contents: nil)
      defer { try? FileManager.default.removeItem(at: output) }
      let handle = try FileHandle(forWritingTo: output)
      let process = Process()
      process.executableURL = probe
      process.arguments = [String(UInt(bitPattern: window.handle))] + arguments
      process.standardOutput = handle
      try process.run()
      let deadline = Date().addingTimeInterval(20)
      while process.isRunning, Date() < deadline {
        window.pump()
        Sleep(1)
      }
      if process.isRunning { process.terminate() }
      try handle.close()
      let text = String(decoding: FileManager.default.contents(atPath: output.path) ?? Data(), as: UTF8.self)
      return (text, !process.isRunning && process.terminationStatus == 0)
    }

    /// Until the window has heard what was asked, taking its messages meanwhile.
    static func heard(_ window: Win32Window, _ events: () -> [ShellEvent], _ wanted: ShellEvent) -> Bool {
      let deadline = Date().addingTimeInterval(5)
      while !events().contains(wanted), Date() < deadline {
        window.pump()
        Sleep(1)
      }
      return events().contains(wanted)
    }

    static func controls(tempo: Double = 120) -> AccessibilityNode {
      AccessibilityNode(
        id: "root", role: .group, name: "",
        children: [
          AccessibilityNode(id: "play", role: .toggle, name: "Play", isOn: false, frame: SIMD4(0, 0, 40, 20)),
          AccessibilityNode(
            id: "tempo", role: .slider, name: "Tempo", value: "\(Int(tempo)) BPM", range: 20...300,
            current: tempo,
            step: 1, frame: SIMD4(50, 0, 40, 20)),
          AccessibilityNode(
            id: "lane", role: .group, name: "Kick", frame: SIMD4(0, 30, 200, 20),
            children: [
              AccessibilityNode(
                id: "lane.step.1", role: .toggle, name: "Step 1", isOn: true, frame: SIMD4(0, 30, 10, 20))
            ]),
          AccessibilityNode(id: "top", role: .button, name: "Return to Start", frame: SIMD4(100, 0, 40, 20)),
          AccessibilityNode(
            id: "bar", role: .text, name: "Position", value: "Bar 1", frame: SIMD4(150, 0, 60, 20)),
        ])
    }

    /// Read as a screen reader reads it: each control's role, name, state and value, under what holds
    /// it; and the window says it is being read. Told again, it is read as it is now.
    @Test func theControlsAreRead() throws {
      let window = try Win32Window(title: "Driftbox test", width: 320, height: 200, visible: false)
      defer { window.close() }
      window.describe(Self.controls())
      let (text, done) = try Self.run(window, "describe")
      #expect(done, "\(text)")
      // Written as Windows writes a line's end, which a character takes whole.
      let lines = text.split(whereSeparator: \.isNewline).map(String.init)
      #expect(lines.contains { $0.hasSuffix(#"Button "Play" [play] toggle=off"#) }, "\(text)")
      #expect(
        lines.contains { $0.hasSuffix(#"Slider "Tempo" [tempo] range=20..300@120 value="120 BPM""#) },
        "\(text)")
      #expect(lines.contains { $0.hasSuffix(#"Button "Return to Start" [top] invoke"#) }, "\(text)")
      #expect(lines.contains { $0.hasSuffix(#"Text "Position" [bar] value="Bar 1""#) }, "\(text)")
      let lane = try #require(lines.firstIndex { $0.hasSuffix(#"Group "Kick" [lane]"#) }, "\(text)")
      let step = try #require(
        lines.firstIndex { $0.hasSuffix(#"Button "Step 1" [lane.step.1] toggle=on"#) }, "\(text)")
      func depth(_ line: String) -> Int { line.prefix { $0 == " " }.count }
      #expect(step == lane + 1 && depth(lines[step]) == depth(lines[lane]) + 2, "the step under its lane")
      #expect(window.isDescribed)

      window.describe(Self.controls(tempo: 128))
      #expect(try Self.run(window, "describe").text.contains(#"range=20..300@128 value="128 BPM""#))
    }

    /// What a screen reader does to a control arrives as the window's event, on the window's thread;
    /// and a control is asked only what its role can do.
    @Test func whatIsAskedArrives() throws {
      let window = try Win32Window(title: "Driftbox test", width: 320, height: 200, visible: false)
      defer { window.close() }
      var events: [ShellEvent] = []
      window.onEvent = { events.append($0) }
      window.describe(Self.controls())
      #expect(try Self.run(window, "toggle", "play").done)
      #expect(Self.heard(window, { events }, .accessibility(.press("play"))))
      #expect(try Self.run(window, "set", "tempo", "128").done)
      #expect(Self.heard(window, { events }, .accessibility(.set("tempo", 128))))
      #expect(try Self.run(window, "invoke", "top").done)
      #expect(Self.heard(window, { events }, .accessibility(.press("top"))))
      #expect(try !Self.run(window, "invoke", "play").done, "a toggle is not a button")
    }
  }
#endif
