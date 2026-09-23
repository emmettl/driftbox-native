#if os(Windows)
  import CWASAPI
  import DriftboxHost
  import Foundation
  import Synchronization
  import WinSDK

  /// One device playing a mixer, on a thread of its own, until it is stopped or the device goes.
  ///
  /// Everything WASAPI is made, used and let go of on that thread: the device, the client, the
  /// render service. The interface's thread only starts it, is told how that went, and stops it,
  /// so the stream is indifferent to that thread's COM apartment — which, for a window with file
  /// dialogs in it, is not the one audio would choose.
  ///
  /// Shared mode, event driven, 32-bit float stereo at the engine's rate. Windows converts to the
  /// device's own format, which is what `AUTOCONVERTPCM` asks for: the engine renders at one rate
  /// whatever the device runs at, as it does on the Mac.
  final class WASAPIStream: @unchecked Sendable {
    let deviceID: String
    /// How long after rendering a frame is heard: the stream's latency and one period.
    private(set) var latency: Double = 0
    /// Frames the device takes at a time, for whoever wants to say so.
    private(set) var period = 0
    private let mixer: Mixer
    private let sampleRate: Double
    private let running = Atomic<Bool>(true)
    /// Set by the render thread when the device goes away under it.
    let invalidated = Atomic<Bool>(false)
    private var wake: HANDLE?
    /// Whether the render thread has been waited for. The owning thread's alone.
    private var joined = false
    private let finished = DispatchSemaphore(value: 0)
    /// Called on the render thread, once, when it stops for a reason of the device's own.
    private let onLost: @Sendable () -> Void

    /// Start playing `mixer` through the device `deviceID`. Throws with the reason it could not.
    init(deviceID: String, mixer: Mixer, sampleRate: Double, onLost: @escaping @Sendable () -> Void) throws {
      self.deviceID = deviceID
      self.mixer = mixer
      self.sampleRate = sampleRate
      self.onLost = onLost
      wake = CreateEventW(nil, false, false, nil)
      let started = DispatchSemaphore(value: 0)
      let outcome = Outcome()
      let thread = Thread { [self] in run(started: started, outcome: outcome) }
      thread.name = "Driftbox audio"
      thread.stackSize = 1 << 20
      thread.start()
      started.wait()
      if let failure = outcome.failure {
        join()
        throw StreamError(message: failure)
      }
      latency = outcome.latency
      period = outcome.period
    }

    /// Stop, and wait until the render thread has let go of everything. The owner must: the
    /// thread holds the stream until it ends, so a stream let go of while running keeps playing.
    func stop() {
      running.store(false, ordering: .releasing)
      if let wake { SetEvent(wake) }
      join()
    }

    private func join() {
      guard !joined else { return }
      joined = true
      finished.wait()
      if let wake { CloseHandle(wake) }
      wake = nil
    }

    struct StreamError: Error, CustomStringConvertible {
      var message: String
      var description: String { message }
    }

    private final class Outcome: @unchecked Sendable {
      var failure: String?
      var latency: Double = 0
      var period = 0
    }

    // MARK: - The render thread

    private func run(started: DispatchSemaphore, outcome: Outcome) {
      COM.initialize(multithreaded: true)
      defer {
        CoUninitialize()
        finished.signal()
      }
      guard let enumerator = DeviceEnumerator(), let device = enumerator.device(id: deviceID) else {
        outcome.failure = "the device is not there"
        started.signal()
        return
      }
      defer { _ = device.pointee.lpVtbl.pointee.Release(device) }

      var raw: UnsafeMutableRawPointer?
      var iid = COM.iidAudioClient
      guard
        device.pointee.lpVtbl.pointee.Activate(device, &iid, DWORD(CLSCTX_INPROC_SERVER.rawValue), nil, &raw)
          .succeeded, let raw
      else {
        outcome.failure = "the device would not open"
        started.signal()
        return
      }
      let client = raw.assumingMemoryBound(to: IAudioClient.self)
      defer { _ = client.pointee.lpVtbl.pointee.Release(client) }

      var format = WAVEFORMATEX(
        wFormatTag: WORD(WAVE_FORMAT_IEEE_FLOAT), nChannels: 2, nSamplesPerSec: DWORD(sampleRate),
        nAvgBytesPerSec: DWORD(sampleRate) * 8, nBlockAlign: 8, wBitsPerSample: 32, cbSize: 0)
      let flags =
        DWORD(AUDCLNT_STREAMFLAGS_EVENTCALLBACK) | DWORD(AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM)
        | DWORD(AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY)
      let initialized = client.pointee.lpVtbl.pointee.Initialize(
        client, AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, &format, nil)
      guard initialized.succeeded else {
        outcome.failure =
          "the device would not take the stream (\(String(UInt32(bitPattern: initialized), radix: 16)))"
        started.signal()
        return
      }
      var bufferFrames: UINT32 = 0
      var streamLatency: REFERENCE_TIME = 0
      var defaultPeriod: REFERENCE_TIME = 0
      _ = client.pointee.lpVtbl.pointee.GetBufferSize(client, &bufferFrames)
      _ = client.pointee.lpVtbl.pointee.GetStreamLatency(client, &streamLatency)
      _ = client.pointee.lpVtbl.pointee.GetDevicePeriod(client, &defaultPeriod, nil)
      guard client.pointee.lpVtbl.pointee.SetEventHandle(client, wake).succeeded else {
        outcome.failure = "the device would not signal"
        started.signal()
        return
      }
      var serviceIID = COM.iidAudioRenderClient
      var service: UnsafeMutableRawPointer?
      guard client.pointee.lpVtbl.pointee.GetService(client, &serviceIID, &service).succeeded, let service
      else {
        outcome.failure = "the device would not render"
        started.signal()
        return
      }
      let renderer = service.assumingMemoryBound(to: IAudioRenderClient.self)
      defer { _ = renderer.pointee.lpVtbl.pointee.Release(renderer) }

      // Everything the loop touches, allocated before it starts.
      let capacity = Int(bufferFrames)
      let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
      let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
      let scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
      let scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
      defer {
        left.deallocate()
        right.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
      }

      // The first buffer silent, so the device has something while the loop gets going.
      var data: UnsafeMutablePointer<BYTE>?
      if renderer.pointee.lpVtbl.pointee.GetBuffer(renderer, bufferFrames, &data).succeeded {
        _ = renderer.pointee.lpVtbl.pointee.ReleaseBuffer(
          renderer, bufferFrames, DWORD(AUDCLNT_BUFFERFLAGS_SILENT.rawValue))
      }
      var task: DWORD = 0
      let priority = "Pro Audio".withCString(encodedAs: UTF16.self) {
        AvSetMmThreadCharacteristicsW($0, &task)
      }
      defer { if let priority { AvRevertMmThreadCharacteristics(priority) } }

      guard client.pointee.lpVtbl.pointee.Start(client).succeeded else {
        outcome.failure = "the device would not start"
        started.signal()
        return
      }
      outcome.latency = Double(streamLatency + defaultPeriod) / 10_000_000
      outcome.period = Int(Double(defaultPeriod) / 10_000_000 * sampleRate)
      started.signal()

      mixer.rendering.store(true, ordering: .releasing)
      var lost = false
      while running.load(ordering: .acquiring) {
        WaitForSingleObject(wake, 2000)
        guard running.load(ordering: .acquiring) else { break }
        var padding: UINT32 = 0
        guard client.pointee.lpVtbl.pointee.GetCurrentPadding(client, &padding).succeeded else {
          lost = true
          break
        }
        let frames = bufferFrames - padding
        guard frames > 0 else { continue }
        guard renderer.pointee.lpVtbl.pointee.GetBuffer(renderer, frames, &data).succeeded, let data else {
          lost = true
          break
        }
        let count = Int(frames)
        mixer.render(
          frames: count, left: left, right: right, scratchLeft: scratchLeft, scratchRight: scratchRight)
        let out = UnsafeMutableRawPointer(data).assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
          out[frame * 2] = left[frame]
          out[frame * 2 + 1] = right[frame]
        }
        _ = renderer.pointee.lpVtbl.pointee.ReleaseBuffer(renderer, frames, 0)
        mixer.buffers.add(1, ordering: .releasing)
      }
      mixer.rendering.store(false, ordering: .releasing)
      _ = client.pointee.lpVtbl.pointee.Stop(client)
      if lost {
        invalidated.store(true, ordering: .releasing)
        onLost()
      }
    }
  }
#endif
