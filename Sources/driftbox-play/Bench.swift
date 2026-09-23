import DriftboxEngine
import DriftboxHost
import DriftboxSeq

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#endif

/// `--bench`: no audio device. The engine runs as fast as it goes, then paced as a device would
/// pace it, and says what each costs. It needs nothing from the platform, so it is the same
/// everywhere, including where there is no player yet — and it takes nothing from Foundation, so
/// that on Android it links without it.
func runBench(_ song: Song, named name: String) {
  let host = EngineHost(sampleRate: 48000)
  host.load(song)
  host.send(.play)
  let frames = 48000 * 20
  let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
  let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
  defer {
    left.deallocate()
    right.deallocate()
  }
  let began = HostTime.now()
  for _ in 0..<(frames / 512) { host.render(frames: 512, left: left, right: right) }
  let took = HostTime.seconds(from: began, to: HostTime.now())
  let load = host.takeLoad()
  print(
    "20s of \(name) in \(fixed(took, 2))s: \(fixed(took / 20 * 100, 1))% of real time"
      + " (\(fixed(load.fraction * 100, 1))% by the thread's clock)")
  // And paced as a device would pace it, sleeping between calls, to see what waking costs.
  for _ in 0..<(48000 * 5 / 512) {
    pause(512.0 / 48000)
    host.render(frames: 512, left: left, right: right)
  }
  let paced = host.takeLoad()
  print(
    "paced, one call every 10.7ms: \(fixed(paced.fraction * 100, 1))% by the thread's clock,"
      + " longest \(fixed(paced.longestMilliseconds, 2))ms")
}

/// Sleeps the calling thread, as `Thread.sleep` does.
private func pause(_ seconds: Double) {
  #if os(Windows)
    Sleep(DWORD(seconds * 1000))
  #else
    var interval = timespec(tv_sec: 0, tv_nsec: Int(seconds * 1e9))
    nanosleep(&interval, nil)
  #endif
}

/// `x` to `places` decimal places, as `%.nf` prints it.
private func fixed(_ x: Double, _ places: Int) -> String {
  var scale = 1
  for _ in 0..<places { scale *= 10 }
  let scaled = Int((abs(x) * Double(scale)).rounded())
  let sign = x < 0 && scaled != 0 ? "-" : ""
  guard places > 0 else { return "\(sign)\(scaled)" }
  let fraction = String(scaled % scale)
  return "\(sign)\(scaled / scale)." + String(repeating: "0", count: places - fraction.count) + fraction
}
