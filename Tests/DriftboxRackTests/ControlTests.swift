import Foundation
import Testing

@testable import DriftboxRack

/// What the fixtures cannot see: a meter's and a tuner's readings, which never reach the audio,
/// and the Combinator's routing rules beyond the cases rendered.
struct ControlTests {
  /// Drives one processor block by block, with every param held at a value.
  final class Bench {
    let frames = 128
    let inlets: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let outlets: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let params: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let inletCount: Int, outletCount: Int, paramCount: Int
    var processor: RackProcessor

    init(_ type: String, params values: [Double], sampleRate: Double = 48000) {
      let def = RackModules.registry[type]!
      inletCount = def.inlets.reduce(0) { $0 + $1.channels }
      outletCount = def.outlets.reduce(0) { $0 + $1.channels }
      paramCount = def.params.count
      processor = RackModules.make(type, sampleRate: sampleRate, id: type)!
      func table(_ count: Int) -> UnsafeMutablePointer<UnsafeMutablePointer<Float>> {
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: max(1, count))
        for index in 0..<count {
          table[index] = .allocate(capacity: 128)
          table[index].initialize(repeating: 0, count: 128)
        }
        return table
      }
      inlets = table(inletCount)
      outlets = table(outletCount)
      params = table(paramCount)
      for (index, value) in values.enumerated() { params[index].update(repeating: Float(value), count: 128) }
    }

    deinit {
      for (table, count) in [(inlets, inletCount), (outlets, outletCount), (params, paramCount)] {
        for index in 0..<count { table[index].deallocate() }
        table.deallocate()
      }
      processor.release()
    }

    /// One block with `input` on the first inlet.
    func run(_ input: (Int) -> Float) {
      if inletCount > 0 { for i in 0..<frames { inlets[0][i] = input(i) } }
      let context = ProcessContext(
        frames: frames,
        transport: Transport(tempo: 120, running: false, beat: 0, beatsPerBlock: 0, shuffle: 0),
        data: DataSlots(base: nil, count: 0), host: .none, voiceInlets: nil,
        inletConnected: Flags(base: nil, count: 0), outletConnected: Flags(base: nil, count: 0),
        voice: .single)
      processor.process(
        inlets: Slots(base: inlets, count: inletCount), outlets: Slots(base: outlets, count: outletCount),
        params: Slots(base: params, count: paramCount), context: context)
    }
  }

  /// A sine at `amplitude`, as float32, for `blocks` blocks from the start.
  static func sine(_ bench: Bench, frequency: Double, amplitude: Double, blocks: Int = 40) {
    for block in 0..<blocks {
      bench.run { i in Float(amplitude * sin((2 * Double.pi * frequency * Double(block * 128 + i)) / 48000)) }
    }
  }

  /// The reference's readings for the same sines, from its `TunerProcessor` and `MeterProcessor`
  /// driven the same way (meter sensitivity 1.5, release 0.3): frequency, clarity, the tuner's
  /// level and peak, then the meter's level, peak, envelope and eighth waveform point.
  static let reference: [(Double, Double, [Double])] = [
    (
      220, 0.5,
      [
        219.9865754003862, 0.997990071773529, 0.3396948671029142, 0.49998459219932556, 0.5095423006543717,
        0.7499768882989883, 0.701773821193453, -0.17508402466773987,
      ]
    ),
    (
      82.41, 0.3,
      [
        82.40811576490518, 0.9999850988388062, 0.2555290893978015, 0.29999616742134094, 0.3832936340967023,
        0.4499942511320114, 0.4258485754675391, -0.2680221199989319,
      ]
    ),
    (
      1318.5, 0.8,
      [
        1319.5806469024274, 0.9971203207969666, 0.5655762616224808, 0.7999992370605469, 0.848364392433722,
        1.1999988555908203, 1.1196402732956512, -0.8128291368484497,
      ]
    ),
  ]

  static func close(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= 1e-9 * max(1, abs(b))
  }

  @Test(arguments: 0..<3)
  func theTunerAndMeterReadAsTheReferenceDoes(index: Int) throws {
    let (frequency, amplitude, expected) = Self.reference[index]
    let tuner = Bench("tuner", params: [440, 0])
    let meter = Bench("meter", params: [1.5, 0.3, 0])
    Self.sine(tuner, frequency: frequency, amplitude: amplitude)
    Self.sine(meter, frequency: frequency, amplitude: amplitude)

    let tuned = try #require(tuner.processor.meter())
    #expect(Self.close(tuned.frequency, expected[0]), "frequency \(tuned.frequency ?? -1)")
    #expect(Self.close(tuned.clarity, expected[1]))
    #expect(Self.close(tuned.level, expected[2]))
    #expect(Self.close(tuned.peak, expected[3]))
    #expect(tuned.envelope == tuned.level)
    #expect(tuned.waveform.count == 48)
    // Asking twice without a block between is the same answer, as the reference's cache gives.
    #expect(tuner.processor.meter()?.frequency == tuned.frequency)

    let metered = try #require(meter.processor.meter())
    #expect(Self.close(metered.level, expected[4]))
    #expect(Self.close(metered.peak, expected[5]))
    #expect(Self.close(metered.envelope, expected[6]))
    #expect(metered.waveform.count == 48)
    #expect(Self.close(Double(metered.waveform[7]), expected[7]))
    #expect(metered.frequency == nil)
  }

  /// A tuner hearing nothing names nothing, and one that has heard too little does not guess.
  @Test func aQuietTunerIsBlank() throws {
    let tuner = Bench("tuner", params: [440, 0])
    for _ in 0..<40 { tuner.run { _ in 0 } }
    let quiet = try #require(tuner.processor.meter())
    #expect(quiet.frequency == 0 && quiet.clarity == 0)

    let early = Bench("tuner", params: [440, 0])
    Self.sine(early, frequency: 220, amplitude: 0.5, blocks: 4)
    #expect(early.processor.meter()?.frequency == 0)
  }

  /// Only the meter and the tuner have anything to show.
  @Test func onlyTheMetersRead() {
    for type in ["follower", "quantizer", "line-mixer", "combi"] {
      let bench = Bench(type, params: [])
      bench.run { _ in 0.5 }
      #expect(bench.processor.meter() == nil, "\(type)")
    }
  }

  // MARK: - Routings

  static func patch(_ routes: [ModRoute], rotary: Double = 127) -> Patch {
    Patch(
      modules: [
        PatchModule(id: "macro", type: "combi", params: ["rotary1": rotary]),
        PatchModule(id: "filter", type: "svf"),
      ],
      cables: [], modulation: routes)
  }

  static func route(_ to: String, _ min: Double? = nil, _ max: Double? = nil) -> ModRoute {
    ModRoute(from: PortReference("macro", "rotary1"), to: PortReference("filter", to), min: min, max: max)
  }

  @Test func aRouteMovesItsTarget() {
    let applied = applyModulation(
      Self.patch([Self.route("cutoff", 100, 200)], rotary: 63.5), registry: RackModules.registry)
    #expect(applied.modules[1].params["cutoff"] == 150)
    // The source is untouched, and so is the list of routes.
    #expect(applied.modules[0] == Self.patch([]).modules[0].with(rotary: 63.5))
    #expect(applied.modulation.count == 1)
  }

  @Test func aPatchWithNothingToChangeComesBackAsItWas() {
    let patch = Self.patch([Self.route("cutoff", 1000, 1000)])
    #expect(applyModulation(patch, registry: RackModules.registry) == patch)
    let unknown = Self.patch([
      Self.route("nothing"),
      ModRoute(from: PortReference("ghost", "x"), to: PortReference("filter", "cutoff")),
    ])
    #expect(applyModulation(unknown, registry: RackModules.registry) == unknown)
  }

  /// A hidden param is the host's, and a route onto one is skipped rather than obeyed.
  @Test func aHiddenParamIsNotRouted() {
    var registry = RackModules.registry
    registry["svf"]!.params[0].hidden = true
    let patch = Self.patch([Self.route("cutoff", 100, 200)])
    #expect(applyModulation(patch, registry: registry) == patch)
  }

  /// Compiling applies the routes, so a patch that never went through a host still plays them.
  @Test func compilingAppliesTheRoutes() throws {
    let plan = compile(Self.patch([Self.route("resonance", 0.9, 0.1)], rotary: 0))
    let slot = try #require(plan.slots["filter"]?["resonance"])
    #expect(plan.params[slot].value == 0.9)
  }
}

extension PatchModule {
  fileprivate func with(rotary: Double) -> PatchModule {
    var copy = self
    copy.params["rotary1"] = rotary
    return copy
  }
}
