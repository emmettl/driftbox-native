#if os(Windows)
  import CWASAPI
  import DriftboxHost
  import Foundation
  import Synchronization
  import WinSDK

  /// One device heard into a `LiveInput`, on a thread of its own, until it is stopped or the
  /// device goes: `WASAPIStream`'s other half.
  ///
  /// As with the output, everything WASAPI is made, used and let go of on that thread, and the
  /// stream is shared mode, event driven, 32-bit float stereo at the engine's rate, converted by
  /// Windows from whatever the device gives — a mono microphone arrives as the same sound on both
  /// sides, which is what the Audio Input module expects of one.
  final class WASAPICapture: @unchecked Sendable {
    let deviceID: String
    private let input: LiveInput
    private let sampleRate: Double
    private let running = Atomic<Bool>(true)
    /// Set by the capture thread when the device goes away under it.
    let invalidated = Atomic<Bool>(false)
    private var wake: HANDLE?
    private var joined = false
    private let finished = DispatchSemaphore(value: 0)
    /// Called on the capture thread, once, when it stops for a reason of the device's own.
    private let onLost: @Sendable () -> Void

    /// Start hearing the device `deviceID` into `input`. Throws with the reason it could not.
    init(deviceID: String, input: LiveInput, sampleRate: Double, onLost: @escaping @Sendable () -> Void)
      throws
    {
      self.deviceID = deviceID
      self.input = input
      self.sampleRate = sampleRate
      self.onLost = onLost
      wake = CreateEventW(nil, false, false, nil)
      let started = DispatchSemaphore(value: 0)
      let outcome = Outcome()
      let thread = Thread { [self] in run(started: started, outcome: outcome) }
      thread.name = "Driftbox audio in"
      thread.stackSize = 1 << 20
      thread.start()
      started.wait()
      if let failure = outcome.failure {
        join()
        throw WASAPIStream.StreamError(message: failure)
      }
    }

    /// Stop, and wait until the capture thread has let go of the device.
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

    private final class Outcome: @unchecked Sendable {
      var failure: String?
    }

    /// What a refusal means to the person it stops, where it is one they can do something about.
    static func reason(_ result: HRESULT, doing what: String) -> String {
      if result == COM.accessDenied {
        return "Windows is not letting Driftbox listen. Turn on microphone access for desktop apps in "
          + "Settings, Privacy & security, Microphone."
      }
      if result == COM.deviceInUse { return "another program has it to itself." }
      return "\(what) (\(String(UInt32(bitPattern: result), radix: 16)))"
    }

    // MARK: - The capture thread

    private func run(started: DispatchSemaphore, outcome: Outcome) {
      COM.initialize(multithreaded: true)
      defer {
        CoUninitialize()
        finished.signal()
      }
      func fail(_ reason: String) {
        outcome.failure = reason
        started.signal()
      }
      guard let enumerator = DeviceEnumerator(flow: eCapture), let device = enumerator.device(id: deviceID)
      else {
        return fail("the device is not there")
      }
      defer { _ = device.pointee.lpVtbl.pointee.Release(device) }

      var raw: UnsafeMutableRawPointer?
      var iid = COM.iidAudioClient
      let activated = device.pointee.lpVtbl.pointee.Activate(
        device, &iid, DWORD(CLSCTX_INPROC_SERVER.rawValue), nil, &raw)
      guard activated.succeeded, let raw else {
        return fail(Self.reason(activated, doing: "the device would not open"))
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
        return fail(Self.reason(initialized, doing: "the device would not give a stream"))
      }
      var defaultPeriod: REFERENCE_TIME = 0
      _ = client.pointee.lpVtbl.pointee.GetDevicePeriod(client, &defaultPeriod, nil)
      guard client.pointee.lpVtbl.pointee.SetEventHandle(client, wake).succeeded else {
        return fail("the device would not signal")
      }
      var serviceIID = COM.iidAudioCaptureClient
      var service: UnsafeMutableRawPointer?
      guard client.pointee.lpVtbl.pointee.GetService(client, &serviceIID, &service).succeeded, let service
      else { return fail("the device would not capture") }
      let capturer = service.assumingMemoryBound(to: IAudioCaptureClient.self)
      defer { _ = capturer.pointee.lpVtbl.pointee.Release(capturer) }

      // Two of the device's pieces in hand: one arriving while the rack takes the last.
      input.prepare(hold: Int(Double(defaultPeriod) / 10_000_000 * sampleRate) * 2)
      var task: DWORD = 0
      let priority = "Pro Audio".withCString(encodedAs: UTF16.self) {
        AvSetMmThreadCharacteristicsW($0, &task)
      }
      defer { if let priority { AvRevertMmThreadCharacteristics(priority) } }

      let begun = client.pointee.lpVtbl.pointee.Start(client)
      guard begun.succeeded else { return fail(Self.reason(begun, doing: "the device would not start")) }
      started.signal()

      var lost = false
      loop: while running.load(ordering: .acquiring) {
        WaitForSingleObject(wake, 2000)
        guard running.load(ordering: .acquiring) else { break }
        // Everything the device has, which may be more than one piece after a late wake.
        while true {
          var waiting: UINT32 = 0
          guard capturer.pointee.lpVtbl.pointee.GetNextPacketSize(capturer, &waiting).succeeded else {
            lost = true
            break loop
          }
          guard waiting > 0 else { break }
          var data: UnsafeMutablePointer<BYTE>?
          var frames: UINT32 = 0
          var bufferFlags: DWORD = 0
          guard
            capturer.pointee.lpVtbl.pointee.GetBuffer(capturer, &data, &frames, &bufferFlags, nil, nil)
              .succeeded
          else {
            lost = true
            break loop
          }
          if bufferFlags & DWORD(AUDCLNT_BUFFERFLAGS_SILENT.rawValue) != 0 || data == nil {
            input.writeSilence(frames: Int(frames))
          } else if let data {
            input.write(
              UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), frames: Int(frames), channels: 2)
          }
          _ = capturer.pointee.lpVtbl.pointee.ReleaseBuffer(capturer, frames)
        }
      }
      _ = client.pointee.lpVtbl.pointee.Stop(client)
      if lost {
        invalidated.store(true, ordering: .releasing)
        onLost()
      }
    }
  }
#endif
