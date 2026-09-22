// Drive, distortion, cabinet, eq, imager, compressor, limiter: not yet ported. The family's processors are one enum
// here, behind one case of `RackProcessor`, so its modules can be added without touching anyone
// else's.

public enum ShapingProcessor {
  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {}

  func meter() -> MeterReading? { nil }

  mutating func release() {}
}

extension RackModules {
  static let shapingDefs: [ModuleDef] = []

  static func makeShaping(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo)
    -> ShapingProcessor?
  {
    nil
  }
}
