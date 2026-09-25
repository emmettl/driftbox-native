#if os(Android)
  import DriftboxHost
  import DriftboxRackSession

  /// The rack on the phone: its catalogue read from where the app unpacked it, and every patch in
  /// it opened in a `RackSession`, compiled, and run with its transport going and a note held, as
  /// the desktop's rack would play it, until it sounds. Each says in which second it did, and what
  /// a second cost the phone. Pressure System, a song, is quiet until its seventh, on Windows as
  /// here; acid's first second peaks at 0.179 on both.
  enum RackCheck {
    static let sampleRate = 48000.0
    static let longest = 8

    @MainActor
    static func run() -> String {
      let entries = PatchEntry.all
      guard !entries.isEmpty else {
        return "FAIL no patches, looking in \(RackCatalogue.resources?.path ?? "nowhere")"
      }
      var lines = ["\(entries.count) patches and \(ModuleFace.all.count) modules' faces"]
      for entry in entries {
        guard let patch = entry.load() else {
          lines.append("FAIL \(entry.id): its patch does not load")
          continue
        }
        let rack = RackSession(sampleRate: sampleRate)
        rack.open(patch, name: entry.name)
        guard rack.patch.modules.count == patch.modules.count else {
          let opened = rack.patch.modules.count
          lines.append("FAIL \(entry.id): \(opened) of \(patch.modules.count) modules opened")
          continue
        }
        rack.listen()
        rack.toggleRunning()
        rack.noteDown(48)
        // Second by second until it sounds: a song's patch can take a few bars to come in.
        var seconds = 0
        var peak: Float = 0
        var milliseconds = 0.0
        while peak <= 0.001, seconds < longest {
          let next = second(of: rack.host)
          (peak, seconds, milliseconds) = (next.peak, seconds + 1, milliseconds + next.milliseconds)
        }
        let cost = "a second in \(tenths(milliseconds / Double(seconds)))ms"
        lines.append(
          peak > 0.001
            ? "PASS \(entry.id) sounds in its second \(seconds), peak \(RackDisplay.fixed(Double(peak), 3)); "
              + cost
            : "FAIL \(entry.id): nothing above 0.001 in \(longest) seconds; \(cost)")
      }
      // Recordings, which a module asks for from Android's picker, read as the rack reads them here.
      if let resources = RackCatalogue.resources {
        lines += DecodingCheck.run(in: resources.appending(path: "decoding-check"))
      }
      return lines.joined(separator: "\n")
    }

    /// A second of `host`, in the blocks the phone's audio asks for: its loudest sample, and how
    /// long it took.
    static func second(of host: RackHost) -> (peak: Float, milliseconds: Double) {
      let block = 192
      var left = [Float](repeating: 0, count: block)
      var right = [Float](repeating: 0, count: block)
      var peak: Float = 0
      let began = HostTime.now()
      for _ in 0..<Int(sampleRate) / block {
        left.withUnsafeMutableBufferPointer { l in
          right.withUnsafeMutableBufferPointer { r in
            host.render(frames: block, left: l.baseAddress!, right: r.baseAddress!)
          }
        }
        for index in 0..<block { peak = max(peak, abs(left[index]), abs(right[index])) }
      }
      return (peak, HostTime.seconds(from: began, to: HostTime.now()) * 1000)
    }

    static func tenths(_ value: Double) -> String {
      let tenths = Int((value * 10).rounded())
      return "\(tenths / 10).\(tenths % 10)"
    }
  }
#endif
