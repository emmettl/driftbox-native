#if os(Android)
  import Android
  import DriftboxHost
  import DriftboxText
  import DriftboxTextAndroid

  /// The typesetter, held on the phone to what `TypesetterTests` holds every platform's to, one
  /// check for one, since Swift Testing does not run on a phone yet (see `GPUCheck`). A check
  /// changed there is changed here.
  ///
  /// The checks run on a thread of Swift's own, as the render thread is, so that the typesetter is
  /// reached the way the scenes will reach it: attached to Java on its first call, and let go of as
  /// it ends.
  enum TextCheck {
    static func run(env: UnsafeMutablePointer<JNIEnv?>) -> String {
      guard let typesetter = AndroidTypesetter(env: env) else {
        return "FAIL no typesetter: it wants Android 12 and the app's Java"
      }
      final class Box: @unchecked Sendable {
        let typesetter: AndroidTypesetter
        var report = ""
        init(_ typesetter: AndroidTypesetter) { self.typesetter = typesetter }
      }
      let box = Box(typesetter)
      var thread = pthread_t()
      pthread_create(
        &thread, nil,
        { context in
          let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
          box.report = TextCheck.checks(box.typesetter)
          return nil
        }, Unmanaged.passUnretained(box).toOpaque())
      pthread_join(thread, nil)
      return box.report
    }

    static let arial = FontRequest(families: ["Arial"], weight: 400, size: 100)

    static func checks(_ typesetter: any Typesetter) -> String {
      let line = typesetter.line("Driftbox", font: arial)
      var lines = ["set in \(line.family), \(line.glyphs.count) glyphs over \(line.width) pixels"]
      let all: [(String, (any Typesetter, inout [String]) -> Void)] = [
        ("a font falls back through its families", fallsBack),
        ("a line is glyphs along the baseline", alongTheBaseline),
        ("width scales with size", widthScales),
        ("pairs are kerned", kerned),
        ("trailing spaces are measured", trailingSpaces),
        ("coverage is the glyph on its baseline", coverage),
        ("a heavier weight is more ink", heavier),
      ]
      for (name, check) in all {
        var failures: [String] = []
        check(typesetter, &failures)
        lines.append(failures.isEmpty ? "PASS \(name)" : "FAIL \(name): \(failures.joined(separator: "; "))")
      }
      lines.append(timing(typesetter))
      return lines.joined(separator: "\n")
    }

    // MARK: - The checks, as TypesetterTests has them

    static func fallsBack(_ typesetter: any Typesetter, _ failures: inout [String]) {
      let asked = typesetter.line(
        "Driftbox", font: FontRequest(families: ["No Such Face", "Arial"], size: 32))
      expect(
        asked.family == "Arial", "asked for Arial after a face there is not, got \(asked.family)", &failures)
      let none = typesetter.line("Driftbox", font: FontRequest(families: ["No Such Face"], size: 32))
      expect(none.family != "No Such Face", "said it had No Such Face", &failures)
      expect(none.width > 0, "and still sets the line, in the fallback", &failures)
    }

    static func alongTheBaseline(_ typesetter: any Typesetter, _ failures: inout [String]) {
      let line = typesetter.line("Driftbox", font: arial)
      expect(line.glyphs.count == 8, "\(line.glyphs.count) glyphs", &failures)
      expect(line.glyphs.allSatisfy { $0.origin.y == 0 }, "off the baseline", &failures)
      expect(
        zip(line.glyphs, line.glyphs.dropFirst()).allSatisfy { $0.origin.x < $1.origin.x },
        "not left to right",
        &failures)
      expect(line.glyphs.first?.origin.x == 0, "the first at \(line.glyphs.first?.origin.x ?? -1)", &failures)
      expect(line.width > (line.glyphs.last?.origin.x ?? .infinity), "the width \(line.width)", &failures)
      expect(
        line.ascent > 50 && line.ascent < 120, "Arial's ascent is most of an em: \(line.ascent)", &failures)
      expect(line.descent > 10 && line.descent < 40, "and its descent a fifth: \(line.descent)", &failures)
    }

    static func widthScales(_ typesetter: any Typesetter, _ failures: inout [String]) {
      var twice = arial
      twice.size = 200
      let small = typesetter.line("Graphic Lab", font: arial).width
      let large = typesetter.line("Graphic Lab", font: twice).width
      expect(abs(large - small * 2) < 0.01, "\(small) and \(large)", &failures)
    }

    static func kerned(_ typesetter: any Typesetter, _ failures: inout [String]) {
      let pair = typesetter.line("AV", font: arial).width
      let apart = typesetter.line("A", font: arial).width + typesetter.line("V", font: arial).width
      expect(pair < apart - 1, "AV \(pair), A and V \(apart)", &failures)
    }

    static func trailingSpaces(_ typesetter: any Typesetter, _ failures: inout [String]) {
      let bare = typesetter.line("A", font: arial).width
      let spaced = typesetter.line("A ", font: arial).width
      expect(spaced > bare + 10, "A \(bare), A and a space \(spaced)", &failures)
    }

    static func coverage(_ typesetter: any Typesetter, _ failures: inout [String]) {
      let black = FontRequest(families: ["Arial Black", "Arial"], weight: 900, size: 100)
      let line = typesetter.line("I ", font: black)
      guard let letter = line.glyphs.first?.glyph, let coverage = typesetter.coverage(letter, offset: 0)
      else {
        failures.append("no I to cover")
        return
      }
      expect(
        coverage.top < -60 && coverage.top > -80, "a capital's height above the baseline: \(coverage.top)",
        &failures)
      expect(
        coverage.top + coverage.height >= -1 && coverage.top + coverage.height <= 2,
        "and down to it: \(coverage.top + coverage.height)", &failures)
      expect(coverage.left >= 0 && coverage.left < 20, "left \(coverage.left)", &failures)
      expect(
        coverage[coverage.width / 2, coverage.height / 2] == 255,
        "solid through the middle: \(coverage[coverage.width / 2, coverage.height / 2])", &failures)
      expect(coverage[0, coverage.height / 2] < 255, "and antialiased at its edge", &failures)

      if let space = line.glyphs.last?.glyph {
        expect(typesetter.coverage(space, offset: 0) == nil, "a space covered something", &failures)
      } else {
        failures.append("no space")
      }
      let along = typesetter.coverage(letter, offset: 0.5)
      expect(
        along != nil && along?.bytes != coverage.bytes, "half a pixel along is not the same bitmap", &failures
      )
    }

    static func heavier(_ typesetter: any Typesetter, _ failures: inout [String]) {
      func ink(_ weight: Int) -> Int {
        let line = typesetter.line("I", font: FontRequest(families: ["Arial"], weight: weight, size: 100))
        guard let glyph = line.glyphs.first?.glyph, let coverage = typesetter.coverage(glyph, offset: 0)
        else {
          return 0
        }
        return coverage.bytes.reduce(0) { $0 + Int($1) }
      }
      let regular = ink(400)
      let black = ink(900)
      expect(Double(black) > Double(regular) * 1.4, "400 is \(regular) of ink and 900 \(black)", &failures)
    }

    /// What a frame of Graphic Lab's type would cost: a line set, and a glyph covered.
    static func timing(_ typesetter: any Typesetter) -> String {
      let request = FontRequest(families: ["Helvetica Neue", "Arial"], weight: 700, size: 24)
      func each(_ text: String) -> Double {
        let started = HostTime.now()
        for _ in 0..<200 { _ = typesetter.line(text, font: request) }
        return HostTime.seconds(from: started, to: HostTime.now()) / 200 * 1e6
      }
      let short = each("R")
      let long = each(String(repeating: "XEROX NIGHT ", count: 4))
      let glyph = typesetter.line("R", font: request).glyphs[0].glyph
      let again = HostTime.now()
      for index in 0..<200 { _ = typesetter.coverage(glyph, offset: Float(index % 8) / 8) }
      let glyphs = HostTime.seconds(from: again, to: HostTime.now())
      return "a line set in \(Int(short))µs, and \(Int((long - short) / 47))µs a glyph more; "
        + "a glyph covered in \(Int(glyphs / 200 * 1e6))µs"
    }

    static func expect(_ passed: Bool, _ what: String, _ failures: inout [String]) {
      if !passed { failures.append(what) }
    }
  }

#endif
