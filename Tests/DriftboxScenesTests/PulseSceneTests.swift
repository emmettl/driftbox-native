import DriftboxEngine
import DriftboxGPU
import DriftboxScenes
import Testing

#if os(Windows)
  import DriftboxGPUD3D11
#endif

/// Pulse on the GPU layer, held to what the Metal one's test holds it to: dark when nothing is
/// happening, brighter on a kick and fading after it, and different again on a note. On every backend
/// this platform has — Direct3D, on WARP, here.
struct PulseSceneTests {
  static func devices() throws -> [any GPUDevice] {
    #if os(Windows)
      return [try D3D11Device(driver: .software)]
    #else
      return []
    #endif
  }

  static func brightness(_ bytes: [UInt8]) -> Double {
    var total = 0
    for index in stride(from: 0, to: bytes.count, by: 4) {
      total += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
    }
    return Double(total) / Double(bytes.count / 4 * 3 * 255)
  }

  @Test func pulseReactsToWhatIsPlayed() throws {
    for device in try Self.devices() {
      let scene = try PulseScene(device: device)
      let target = try device.makeTarget(width: 160, height: 90)
      func frame(at time: Double, events: [EngineEvent] = []) throws -> [UInt8] {
        scene.draw(SceneInput(time: time, events: events), into: target, on: device)
        return try device.readPixels(target)
      }

      let quiet = try frame(at: 1)
      let kick = allVoices.firstIndex { $0.id == "909.bd" }!
      let struck = try frame(
        at: 1.05, events: [EngineEvent(kind: .hit, frame: 0, voice: kick, level: 1, frequency: 0, flag: 0)])
      let later = try frame(at: 3)
      let note = try frame(
        at: 3.05, events: [EngineEvent(kind: .note, frame: 0, voice: 0, level: 0.6, frequency: 110, flag: 0)])

      #expect(Self.brightness(quiet) < 0.08, "quiet is dark: \(Self.brightness(quiet))")
      #expect(Self.brightness(struck) > Self.brightness(quiet) + 0.005, "a kick lights it")
      #expect(Self.brightness(later) < Self.brightness(struck), "and it fades")
      #expect(note != later, "a note draws something")
    }
  }

  @Test func pulseKeepsItsIdentity() {
    #expect(PulseScene.id == "pulse")
    #expect(PulseScene.accent == SIMD3(1.0, 0.62, 0.2))
  }
}
