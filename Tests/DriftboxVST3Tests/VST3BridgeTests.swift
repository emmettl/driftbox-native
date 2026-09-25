#if os(Windows)
  import CVST3
  import Foundation
  import Testing

  /// The bridge to VST 3 plug-ins, held to the test plug-in the package builds beside the tests,
  /// laid out as an installed plug-in is: found, made, played, set, and kept.
  struct VST3BridgeTests {
    static let gainID = "447269667462" + "6F7854657374" + "4761696E"
    static let synthID = "447269667462" + "6F7854657374" + "53796E74"

    /// The test plug-in as a `.vst3` bundle in a folder of its own: the library the build made, where
    /// an installer would put it.
    static let bundle: String = {
      let build = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      let library = build.appendingPathComponent("DriftboxVST3Fixture.dll")
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "driftbox-vst3-\(UUID().uuidString)")
      let bundle = root.appendingPathComponent("Driftbox Test.vst3")
      let binary = bundle.appendingPathComponent("Contents/x86_64-win")
      try? FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
      try? FileManager.default.copyItem(at: library, to: binary.appendingPathComponent("Driftbox Test.vst3"))
      return bundle.path
    }()

    static func open(_ classID: String, rate: Double = 48000) throws -> OpaquePointer {
      var error = [CChar](repeating: 0, count: 512)
      let plugin = dbvst3_open(bundle, classID, rate, 512, &error, error.count)
      return try #require(plugin, "\(Self.string(error))")
    }

    /// Stereo through `plugin`: `frames` of `input` on both sides, and what came out of each.
    static func process(
      _ plugin: OpaquePointer, _ input: Float = 1, frames: Int = 256, events: [UInt64] = []
    ) -> [[Float]] {
      var left = [Float](repeating: input, count: frames)
      var right = [Float](repeating: input, count: frames)
      var outLeft = [Float](repeating: 9, count: frames)
      var outRight = [Float](repeating: 9, count: frames)
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          outLeft.withUnsafeMutableBufferPointer { ol in
            outRight.withUnsafeMutableBufferPointer { or in
              let inputs: [UnsafePointer<Float>?] = [
                UnsafePointer(l.baseAddress), UnsafePointer(r.baseAddress),
              ]
              let outputs: [UnsafeMutablePointer<Float>?] = [ol.baseAddress, or.baseAddress]
              inputs.withUnsafeBufferPointer { ins in
                outputs.withUnsafeBufferPointer { outs in
                  events.withUnsafeBufferPointer { list in
                    dbvst3_process(
                      plugin, ins.baseAddress, 2, outs.baseAddress, 2, Int32(frames), 120, 0, true,
                      list.baseAddress, Int32(list.count))
                  }
                }
              }
            }
          }
        }
      }
      return [outLeft, outRight]
    }

    /// One block of `plugin` as a rack module plays it: two inlets of `input`, `events` for an
    /// instrument module's MIDI and nil for an effect's, and the four macros.
    static func render(
      _ plugin: OpaquePointer, _ input: Float = 1, frames: Int = 256, events: [UInt64]? = nil,
      macros: [Float] = [0, 0, 0, 0]
    ) -> [Float] {
      let inlets = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
      let outlets = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
      defer { for buffer in inlets + outlets { buffer.deallocate() } }
      for inlet in inlets { inlet.initialize(repeating: input, count: frames) }
      for outlet in outlets { outlet.initialize(repeating: 9, count: frames) }
      let ins: [UnsafeMutablePointer<Float>?] = inlets
      let outs: [UnsafeMutablePointer<Float>?] = outlets
      ins.withUnsafeBufferPointer { ins in
        outs.withUnsafeBufferPointer { outs in
          macros.withUnsafeBufferPointer { macros in
            if let events {
              events.withUnsafeBufferPointer { list in
                dbvst3_render(
                  plugin, ins.baseAddress, outs.baseAddress, Int32(frames), 120, 0, true, list.baseAddress,
                  Int32(list.count), macros.baseAddress, Int32(macros.count))
              }
            } else {
              dbvst3_render(
                plugin, ins.baseAddress, outs.baseAddress, Int32(frames), 120, 0, true, nil, 0,
                macros.baseAddress,
                Int32(macros.count))
            }
          }
        }
      }
      return Array(UnsafeBufferPointer(start: outlets[0], count: frames))
    }

    /// What a C function wrote into `characters`, up to its end.
    static func string(_ characters: [CChar]) -> String {
      String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A C string field as Swift imports one, a tuple of characters, as a string.
    static func text<Field>(_ field: Field) -> String {
      withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A MIDI message at `frame`, packed as the rack packs one.
    static func midi(_ frame: Int, _ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt64 {
      UInt64(frame) << 32 | UInt64(status) << 16 | UInt64(data1) << 8 | UInt64(data2)
    }

    /// The module's two audio plug-ins, and not its controller class, with who made them and what
    /// they are.
    @Test func theModulesPlugInsAreFound() throws {
      var classes = [DBVST3Class](repeating: DBVST3Class(), count: 8)
      var error = [CChar](repeating: 0, count: 512)
      let count = dbvst3_classes(Self.bundle, &classes, 8, &error, error.count)
      #expect(count == 2, "\(Self.string(error))")
      let found = classes.prefix(Int(max(0, count))).map {
        (id: Self.text($0.classID), name: Self.text($0.name), sub: Self.text($0.subCategories))
      }
      #expect(found.map(\.name) == ["Driftbox Test Gain", "Driftbox Test Synth"])
      #expect(found.map(\.id) == [Self.gainID, Self.synthID])
      #expect(found.map(\.sub) == ["Fx", "Instrument|Synth"])
      #expect(dbvst3_classes("C:/nowhere.vst3", nil, 0, &error, error.count) == -1)
      #expect(!Self.string(error).isEmpty, "and says why")
    }

    /// An effect with a controller of its own: made at the rack's rate, it plays stereo through,
    /// at its gain, and says how late it is.
    @Test func anEffectPlays() throws {
      let plugin = try Self.open(Self.gainID)
      defer { dbvst3_close(plugin) }
      #expect(dbvst3_input_channels(plugin) == 2 && dbvst3_output_channels(plugin) == 2)
      #expect(!dbvst3_takes_notes(plugin))
      #expect(dbvst3_latency(plugin) == 32)
      let out = Self.process(plugin, 0.8)
      #expect(out[0].allSatisfy { abs($0 - 0.4) < 1e-6 } && out[1].allSatisfy { abs($0 - 0.4) < 1e-6 })
    }

    /// A param, found by its name, set from the main thread, reaches the audio at the next block,
    /// and is said in its own words.
    @Test func aParamIsSet() throws {
      let plugin = try Self.open(Self.gainID)
      defer { dbvst3_close(plugin) }
      #expect(dbvst3_parameter_count(plugin) == 1)
      var parameter = DBVST3Parameter()
      #expect(dbvst3_parameter(plugin, 0, &parameter))
      #expect(Self.text(parameter.title) == "Gain" && parameter.automatable && parameter.defaultValue == 0.5)
      #expect(!dbvst3_parameter(plugin, 1, &parameter))

      dbvst3_set_parameter(plugin, 0, 0.25)
      #expect(dbvst3_get_parameter(plugin, 0) == 0.25)
      #expect(abs(Self.process(plugin, 1)[0][0] - 0.25) < 1e-6)
      var text = [CChar](repeating: 0, count: 64)
      #expect(dbvst3_parameter_text(plugin, 0, 0.25, &text, text.count))
      #expect(Self.string(text).hasPrefix("0.25"))
    }

    /// Its state is kept and handed back: a new one of it, given the first's, plays as the first did,
    /// and its controller says so.
    @Test func itsStateIsKept() throws {
      let first = try Self.open(Self.gainID)
      defer { dbvst3_close(first) }
      dbvst3_set_parameter(first, 0, 0.75)
      _ = Self.process(first)
      let size = dbvst3_state(first, nil, 0)
      #expect(size > 8)
      var state = [UInt8](repeating: 0, count: Int(size))
      #expect(dbvst3_state(first, &state, size) == size)

      let second = try Self.open(Self.gainID)
      defer { dbvst3_close(second) }
      #expect(dbvst3_set_state(second, state, size))
      #expect(abs(Self.process(second, 1)[0][0] - 0.75) < 1e-6)
      #expect(dbvst3_get_parameter(second, 0) == 0.75)
      #expect(!dbvst3_set_state(second, state, 4), "too short to be one")
    }

    /// An instrument that is one component: silent until a note, which sounds from its frame on, and
    /// stops at its note off.
    @Test func anInstrumentPlaysNotes() throws {
      let plugin = try Self.open(Self.synthID)
      defer { dbvst3_close(plugin) }
      #expect(dbvst3_takes_notes(plugin) && dbvst3_input_channels(plugin) == 0)
      #expect(Self.process(plugin, 0)[0].allSatisfy { $0 == 0 })
      let on = Self.process(plugin, 0, events: [Self.midi(64, 0x90, 69, 127)])[0]
      #expect(on[..<65].allSatisfy { $0 == 0 }, "nothing before its frame")
      #expect(on[65...].contains { abs($0) > 0.1 })
      let off = Self.process(plugin, 0, events: [Self.midi(0, 0x80, 69, 0)])[0]
      #expect(off.allSatisfy { $0 == 0 })
    }

    /// As a rack module plays it: a macro turns the param it is mapped onto, and its controller is
    /// told; unmapped, the param stays where the macro left it, and is set from the main thread again.
    @Test func aMacroTurnsItsParam() throws {
      let plugin = try Self.open(Self.gainID)
      defer { dbvst3_close(plugin) }
      #expect(
        Self.render(plugin, 0.8, macros: [0.25, 0, 0, 0]).allSatisfy { abs($0 - 0.4) < 1e-6 }, "unmapped")
      #expect(dbvst3_mapping(plugin, 0) == -1)

      dbvst3_map(plugin, 0, 0)
      #expect(dbvst3_mapping(plugin, 0) == 0)
      #expect(abs(Self.render(plugin, 1, macros: [0.25, 0, 0, 0])[0] - 0.25) < 1e-6, "sent at once")
      #expect(dbvst3_get_parameter(plugin, 0) == 0.25, "and its controller told")
      #expect(abs(Self.render(plugin, 1, macros: [0.75, 0, 0, 0])[0] - 0.75) < 1e-6)

      dbvst3_map(plugin, 0, -1)
      #expect(abs(Self.render(plugin, 1, macros: [0.1, 0, 0, 0])[0] - 0.75) < 1e-6)
      dbvst3_set_parameter(plugin, 0, 0.5)
      #expect(abs(Self.render(plugin, 1, macros: [0.1, 0, 0, 0])[0] - 0.5) < 1e-6)
      #expect(
        Self.render(plugin, frames: 1024).allSatisfy { $0 == 0 }, "longer than it was made for: silence")
    }

    /// An instrument module's inlets are voltages, not audio; its pitch bend, all fourteen bits of
    /// it, reaches the param the plug-in takes it on; and all notes off ends the note sounding.
    @Test func anInstrumentModuleIsPlayed() throws {
      let plugin = try Self.open(Self.synthID)
      defer { dbvst3_close(plugin) }
      let on = Self.render(plugin, 5, events: [Self.midi(0, 0x90, 69, 127)])
      #expect(abs((on.map(abs).max() ?? 0) - 0.8) < 0.01, "at its level, with nothing of the inlets")
      let bent = Self.render(plugin, 5, events: [Self.midi(0, 0xE0, 0, 64)])
      #expect(abs((bent.map(abs).max() ?? 0) - 8192.0 / 16383) < 0.01)
      let off = Self.render(plugin, 5, events: [Self.midi(0, 0xB0, 123, 0)])
      #expect(off.allSatisfy { $0 == 0 })
    }

    /// One that is not in the module, or not a plug-in at all, is not made, and says why.
    @Test func whatIsNotThereIsNotMade() {
      var error = [CChar](repeating: 0, count: 512)
      #expect(
        dbvst3_open(Self.bundle, "0123456789ABCDEF0123456789ABCDEF", 48000, 512, &error, error.count) == nil)
      #expect(!Self.string(error).isEmpty)
      #expect(dbvst3_open(Self.bundle, "not an id", 48000, 512, &error, error.count) == nil)
    }
  }
#endif
