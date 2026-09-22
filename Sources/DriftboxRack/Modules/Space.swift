// Ping-pong, phaser, the fdn reverb, the looper: not yet ported. The family's processors are one enum
// here, behind one case of `RackProcessor`, so its modules can be added without touching anyone
// else's.

public enum SpaceProcessor {
  @_noAllocation
  mutating func process(_ inlets: Slots, _ outlets: Slots, _ params: Slots, _ context: ProcessContext) {}

  func meter() -> MeterReading? { nil }

  mutating func release() {}
}

extension RackModules {
  static let spaceDefs: [ModuleDef] = []

  static func makeSpace(_ type: String, sampleRate: Double, id: String, voice: VoiceInfo) -> SpaceProcessor? {
    nil
  }
}
