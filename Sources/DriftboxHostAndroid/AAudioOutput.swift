#if os(Android)
  import Android
  import CAAudio
  import DriftboxHost
  import Synchronization

  /// One AAudio stream playing a mixer, until it is stopped or its device goes.
  ///
  /// Low-latency mode, exclusive if the device will give it and shared if not, 32-bit float
  /// stereo at the engine's rate; AAudio converts if the device runs at another. The buffer starts
  /// at one burst, the least a stream can have, and `tune` lets it out a burst at a time once the
  /// render thread has fallen behind: on a Fairphone 6 one burst was enough for the heaviest song,
  /// 2ms, and the speaker about 5ms behind the render.
  ///
  /// AAudio makes the render thread and calls into it. It is kept to the big cores, which AAudio
  /// does not do by itself: on a Fairphone 6, left to the scheduler, it underran a hundred times a
  /// second, and kept to them, not once in thirty seconds of the heaviest song. It also reports
  /// each callback's work to a performance hint session, with a burst as the target, which is how
  /// Android asks a real-time thread to say what it needs. Measured, that holds the clock up only
  /// when the target is tighter than the work, and the render costs the same either way — about
  /// 60% of each 2ms burst, against 16% flat out — because what a callback pays for is the core
  /// waking cold from idle, not its clock. So the hint is there for phones and apps where it
  /// matters, and nothing here depends on it.
  final class AAudioOutput: @unchecked Sendable {
    /// What the stream turned out to be, for whoever wants to say so.
    struct Shape: Sendable {
      var sampleRate: Int
      var framesPerBurst: Int
      var bufferFrames: Int
      var exclusive: Bool
      var cores: [Int]
      var hinted: Bool
    }

    let deviceID: Int32
    private(set) var shape: Shape
    private let stream: OpaquePointer
    private let callback: Callback
    private var stopped = false
    /// Underruns as of the last `tune`.
    private var xrunsTuned = 0

    /// Set when the device goes away under the stream.
    var invalidated: Bool { callback.invalidated.load(ordering: .acquiring) }

    /// Underruns since the stream started: bursts the device wanted and did not get in time.
    var xruns: Int { Int(AAudioStream_getXRunCount(stream)) }

    /// How long after rendering a frame is heard. AAudio's timestamp says when a frame reached the
    /// speaker, so the frames written since it, and the time since it, are the answer; before
    /// there is one, the buffer is.
    var latency: Double {
      var position: Int64 = 0
      var time: Int64 = 0
      let rate = Double(shape.sampleRate)
      guard AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &position, &time) == AAUDIO_OK else {
        return Double(shape.bufferFrames) / rate
      }
      let written = AAudioStream_getFramesWritten(stream)
      let now = Int64(bitPattern: HostTime.now())
      return max(0, Double(written - position) / rate - Double(now - time) / 1e9)
    }

    /// Start playing `mixer` through the device `deviceID`, or the system's for `AAUDIO_UNSPECIFIED`.
    /// Throws with the reason it could not.
    init(
      deviceID: Int32, mixer: Mixer, sampleRate: Double, cores: [Int], onLost: @escaping @Sendable () -> Void
    ) throws(OutputError) {
      self.deviceID = deviceID
      // Made before the stream, since AAudio takes the callbacks' context only while opening. A
      // callback asking for more frames than this at once is rendered in several goes.
      let callback = Callback(mixer: mixer, capacity: 4096, cores: cores, onLost: onLost)
      let context = Unmanaged.passUnretained(callback).toOpaque()
      var opened: OpaquePointer?
      var result = Self.open(
        deviceID: deviceID, sampleRate: sampleRate, exclusive: true, context: context, into: &opened)
      if result != AAUDIO_OK {
        result = Self.open(
          deviceID: deviceID, sampleRate: sampleRate, exclusive: false, context: context, into: &opened)
      }
      guard result == AAUDIO_OK, let opened else {
        throw OutputError(message: "AAudio would not open a stream (\(Self.text(result)))")
      }
      let rate = Int(AAudioStream_getSampleRate(opened))
      guard Double(rate) == sampleRate else {
        AAudioStream_close(opened)
        throw OutputError(message: "the stream runs at \(rate) Hz, not \(Int(sampleRate))")
      }
      let burst = Int(AAudioStream_getFramesPerBurst(opened))
      _ = AAudioStream_setBufferSizeInFrames(opened, Int32(burst))
      self.callback = callback
      stream = opened
      shape = Shape(
        sampleRate: rate, framesPerBurst: burst,
        bufferFrames: Int(AAudioStream_getBufferSizeInFrames(opened)),
        exclusive: AAudioStream_getSharingMode(opened)
          == aaudio_sharing_mode_t(AAUDIO_SHARING_MODE_EXCLUSIVE),
        cores: cores, hinted: false)

      mixer.rendering.store(true, ordering: .releasing)
      result = AAudioStream_requestStart(opened)
      guard result == AAUDIO_OK else {
        stopped = true
        mixer.rendering.store(false, ordering: .releasing)
        AAudioStream_close(opened)
        throw OutputError(message: "the stream would not start (\(Self.text(result)))")
      }
      shape.hinted = callback.startHinting(burstSeconds: Double(burst) / Double(rate))
    }

    deinit { stop() }

    /// A burst more buffer if there have been underruns since last asked, up to what the stream
    /// has room for: latency given up only once it has been shown to be needed. Whoever owns the
    /// stream calls this now and then — once a second is plenty. Whether the buffer grew.
    func tune() -> Bool {
      let now = xruns
      defer { xrunsTuned = now }
      guard now > xrunsTuned else { return false }
      let room = Int(AAudioStream_getBufferCapacityInFrames(stream))
      let wanted = min(shape.bufferFrames + shape.framesPerBurst, room)
      guard wanted > shape.bufferFrames else { return false }
      let set = Int(AAudioStream_setBufferSizeInFrames(stream, Int32(wanted)))
      guard set > shape.bufferFrames else { return false }
      shape.bufferFrames = set
      return true
    }

    /// Sixteen bursts of buffer at once, or back to the one a stream starts with. See
    /// `AAudioRoute.relaxed`.
    func relax(_ relaxed: Bool) {
      let room = Int(AAudioStream_getBufferCapacityInFrames(stream))
      let wanted = relaxed ? min(shape.framesPerBurst * 16, room) : shape.framesPerBurst
      let set = Int(AAudioStream_setBufferSizeInFrames(stream, Int32(wanted)))
      if set > 0 { shape.bufferFrames = set }
      xrunsTuned = xruns
    }

    /// Stop, and wait until AAudio has finished calling back. The owner must: a stream let go of
    /// while running keeps playing.
    func stop() {
      guard !stopped else { return }
      stopped = true
      AAudioStream_requestStop(stream)
      AAudioStream_close(stream)
      callback.mixer.rendering.store(false, ordering: .releasing)
      callback.stopHinting()
    }

    struct OutputError: Error, CustomStringConvertible {
      var message: String
      var description: String { message }
    }

    private static func open(
      deviceID: Int32, sampleRate: Double, exclusive: Bool, context: UnsafeMutableRawPointer,
      into stream: inout OpaquePointer?
    ) -> aaudio_result_t {
      var builder: OpaquePointer?
      let made = AAudio_createStreamBuilder(&builder)
      guard made == AAUDIO_OK, let builder else { return made }
      defer { AAudioStreamBuilder_delete(builder) }
      AAudioStreamBuilder_setDeviceId(builder, deviceID)
      AAudioStreamBuilder_setDirection(builder, aaudio_direction_t(AAUDIO_DIRECTION_OUTPUT))
      AAudioStreamBuilder_setSharingMode(
        builder, aaudio_sharing_mode_t(exclusive ? AAUDIO_SHARING_MODE_EXCLUSIVE : AAUDIO_SHARING_MODE_SHARED)
      )
      AAudioStreamBuilder_setPerformanceMode(
        builder, aaudio_performance_mode_t(AAUDIO_PERFORMANCE_MODE_LOW_LATENCY))
      AAudioStreamBuilder_setFormat(builder, aaudio_format_t(AAUDIO_FORMAT_PCM_FLOAT))
      AAudioStreamBuilder_setChannelCount(builder, 2)
      AAudioStreamBuilder_setSampleRate(builder, Int32(sampleRate))
      AAudioStreamBuilder_setUsage(builder, aaudio_usage_t(AAUDIO_USAGE_MEDIA))
      AAudioStreamBuilder_setContentType(builder, aaudio_content_type_t(AAUDIO_CONTENT_TYPE_MUSIC))
      AAudioStreamBuilder_setDataCallback(builder, renderCallback, context)
      AAudioStreamBuilder_setErrorCallback(builder, errorCallback, context)
      return AAudioStreamBuilder_openStream(builder, &stream)
    }

    private static func text(_ result: aaudio_result_t) -> String {
      String(cString: AAudio_convertResultToText(result))
    }
  }

  /// What the render thread works with, allocated before the stream starts and touched by
  /// nothing else while it runs.
  private final class Callback: @unchecked Sendable {
    let mixer: Mixer
    let capacity: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let scratchLeft: UnsafeMutablePointer<Float>
    let scratchRight: UnsafeMutablePointer<Float>
    /// The cores to keep to, as a CPU set; nil for any.
    let cores: UnsafeMutablePointer<UInt64>?
    let invalidated = Atomic<Bool>(false)
    let onLost: @Sendable () -> Void
    /// The render thread's ID, once it has called back.
    let thread = Atomic<Int32>(0)
    /// The performance hint session, by address; 0 for none.
    let session = Atomic<Int>(0)
    private let report = Bionic.reportWork

    init(mixer: Mixer, capacity: Int, cores: [Int], onLost: @escaping @Sendable () -> Void) {
      self.mixer = mixer
      self.capacity = capacity
      self.onLost = onLost
      left = .allocate(capacity: capacity)
      right = .allocate(capacity: capacity)
      scratchLeft = .allocate(capacity: capacity)
      scratchRight = .allocate(capacity: capacity)
      if cores.isEmpty {
        self.cores = nil
      } else {
        let mask = PerformanceCores.mask(cores)
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: mask.count)
        words.initialize(from: mask, count: mask.count)
        self.cores = words
      }
    }

    deinit {
      left.deallocate()
      right.deallocate()
      scratchLeft.deallocate()
      scratchRight.deallocate()
      cores?.deallocate()
    }

    /// Once the render thread has called back and said which it is, a session for it with a
    /// burst as its target. Waits up to a second for that first callback. Whether there is one.
    func startHinting(burstSeconds: Double) -> Bool {
      guard let manager = Bionic.hintManager?(), let create = Bionic.createHintSession else { return false }
      var waited = 0
      while thread.load(ordering: .acquiring) == 0, waited < 1000 {
        var interval = timespec(tv_sec: 0, tv_nsec: 1_000_000)
        nanosleep(&interval, nil)
        waited += 1
      }
      var id = thread.load(ordering: .acquiring)
      guard id != 0, let made = create(manager, &id, 1, Int64(burstSeconds * 1e9)) else { return false }
      session.store(Int(bitPattern: made), ordering: .releasing)
      return true
    }

    /// After the stream has stopped calling back.
    func stopHinting() {
      let old = session.exchange(0, ordering: .acquiringAndReleasing)
      if let old = OpaquePointer(bitPattern: old) { Bionic.closeHintSession?(old) }
    }

    /// One callback's worth, interleaved into `data`. On the render thread.
    func render(into data: UnsafeMutableRawPointer, frames: Int) {
      if thread.load(ordering: .relaxed) == 0 { firstCallback() }
      let began = HostTime.now()
      let out = data.assumingMemoryBound(to: Float.self)
      var done = 0
      while done < frames {
        let count = min(capacity, frames - done)
        mixer.render(
          frames: count, left: left, right: right, scratchLeft: scratchLeft, scratchRight: scratchRight)
        for frame in 0..<count {
          out[(done + frame) * 2] = left[frame]
          out[(done + frame) * 2 + 1] = right[frame]
        }
        done += count
      }
      mixer.buffers.add(1, ordering: .releasing)
      if let report, let session = OpaquePointer(bitPattern: session.load(ordering: .acquiring)) {
        _ = report(session, Int64(bitPattern: HostTime.now() &- began))
      }
    }

    /// The thread says which it is, and moves to the cores it should be on. Once.
    private func firstCallback() {
      if let cores, let setAffinity = Bionic.setAffinity {
        _ = setAffinity(0, 16 * MemoryLayout<UInt64>.size, cores)
      }
      thread.store(gettid(), ordering: .releasing)
    }

    /// The device went away. AAudio says so on a thread of its own, where the stream must not be
    /// closed; whoever owns it is told, once.
    func lost() {
      if !invalidated.exchange(true, ordering: .acquiringAndReleasing) { onLost() }
    }
  }

  private let renderCallback: AAudioStream_dataCallback = { _, context, data, frames in
    if let context {
      Unmanaged<Callback>.fromOpaque(context)._withUnsafeGuaranteedRef {
        $0.render(into: data, frames: Int(frames))
      }
    }
    return aaudio_data_callback_result_t(AAUDIO_CALLBACK_RESULT_CONTINUE)
  }

  private let errorCallback: AAudioStream_errorCallback = { _, context, error in
    guard let context, error == AAUDIO_ERROR_DISCONNECTED else { return }
    Unmanaged<Callback>.fromOpaque(context)._withUnsafeGuaranteedRef { $0.lost() }
  }
#endif
