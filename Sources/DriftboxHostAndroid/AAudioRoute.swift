#if os(Android)
  import CAAudio
  import DriftboxHost

  /// Where the sound goes on Android, kept there: AAudio's `AudioRouting`.
  ///
  /// The system's output unless another is chosen, which follows headphones and Bluetooth as
  /// Android routes them. AAudio plays through a device by number but cannot list them: that is
  /// Java's `AudioManager`, so the app lists them, and says again as they come and go, through
  /// `list`. A choice that is not there is kept, and the system's is played through until it is.
  ///
  /// A stream whose device goes away ends, and says so on a thread of its own; `apply` makes the
  /// next one. It works out where the sound should be going from scratch, as `WASAPIRoute` does,
  /// so it does not matter what set it off.
  @MainActor
  public final class AAudioRoute: AudioRouting {
    /// The system's output, wherever Android sends it: what nothing chosen plays through.
    public static let system = AudioDevice(id: "system", name: "the phone's output")

    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    /// The devices the app has listed.
    public private(set) var devices: [AudioDevice] = []
    /// AAudio's number for each, by its ID: a number Android gives a device afresh each time it is
    /// plugged in, where the ID, which a choice is kept by, is the same.
    private var numbers: [String: Int32] = [:]

    /// The devices there are now, as the app's `AudioManager` lists them, each with the number
    /// AAudio knows it by: the stream moved if the one it should be on has come or gone.
    public func list(_ listed: [(device: AudioDevice, number: Int32)]) {
      let fresh = Dictionary(listed.map { ($0.device.id, $0.number) }, uniquingKeysWith: { first, _ in first })
      guard listed.map(\.device) != devices || fresh != numbers else { return }
      devices = listed.map(\.device)
      numbers = fresh
      apply()
    }
    public private(set) var current: AudioDevice?
    public let systemDefault: AudioDevice? = AAudioRoute.system
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    public let sampleRate: Double
    public var latency: Double { output?.latency ?? 0 }

    /// Underruns since the stream started.
    public var xruns: Int { output?.xruns ?? 0 }

    /// What the stream is, in words: its device, sharing, burst, buffer, and what the render thread
    /// was given.
    public var details: String? {
      guard let shape = output?.shape else { return nil }
      let tenths = Int((Double(shape.framesPerBurst) / Double(shape.sampleRate) * 10_000).rounded())
      let cores =
        shape.cores.isEmpty ? "any core" : "cores \(shape.cores.map(String.init).joined(separator: ","))"
      return
        "through \(current?.name ?? "nothing"), \(shape.exclusive ? "exclusive" : "shared"), "
        + "\(shape.sampleRate) Hz, "
        + "bursts of \(shape.framesPerBurst) frames (\(tenths / 10).\(tenths % 10)ms), "
        + "buffer of \(shape.bufferFrames), render thread on \(cores), "
        + (shape.hinted ? "performance hint on" : "no performance hint")
    }

    private let mixer = Mixer()
    private var output: AAudioOutput?
    private let cores: [Int]
    private var changed: (@Sendable () -> Void)?

    /// A route playing through the system's output. `hop` is how word from AAudio's thread reaches
    /// the main actor, which on Android is whatever the host drains: the app's looper, or a loop.
    public init(
      chosen: String? = nil, sampleRate: Double = 48000,
      hop: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
      self.chosen = chosen
      self.sampleRate = sampleRate
      cores = PerformanceCores.choose(maximumFrequencies: Bionic.maximumFrequencies())
      changed = { [weak self] in
        hop { MainActor.assumeIsolated { self?.apply() } }
      }
      apply()
    }

    isolated deinit {
      output?.stop()
    }

    public func attach(_ source: RenderSource) {
      mixer.add(source)
    }

    public func detach(_ context: UnsafeMutableRawPointer) {
      mixer.remove(context)
    }

    /// Whether latency is let go of for the sake of never breaking: sixteen bursts of buffer at
    /// once, rather than one grown a burst at a time after underruns. For an app out of view, where
    /// nobody hears how late the sound is, only whether it breaks. Measured on a Fairphone 6 with
    /// the screen off: the render thread's cost went from half of each burst to three quarters,
    /// with nothing drawn keeping the cores awake; a stream left to grow its buffer
    /// underran 246 times in six seconds before it had enough, and one of sixteen bursts once.
    public var relaxed = false {
      didSet { if relaxed != oldValue { output?.relax(relaxed) } }
    }

    /// Lets the stream's buffer out by a burst if it has underrun since last asked, and says so
    /// through `onChange`. Call it now and then; once a second is plenty.
    public func tune() {
      if output?.tune() == true { onChange?() }
    }

    /// Point a stream at the device it should be playing through, and make sure it is.
    /// Whether the route has let go of its device until `resume`.
    public private(set) var suspended = false

    /// Let go of the device, and play through nothing, until `resume`: for a song paused while
    /// another app has the audio, where a stream kept open would only hold on to it.
    public func suspend() {
      suspended = true
      apply()
    }

    public func resume() {
      suspended = false
      apply()
    }

    public func apply() {
      defer { onChange?() }
      guard !suspended else {
        output?.stop()
        output = nil
        current = nil
        error = nil
        return
      }
      guard let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      else {
        output?.stop()
        output = nil
        current = nil
        error = "There is nothing to play through."
        return
      }
      let deviceID =
        target == Self.system ? Int32(AAUDIO_UNSPECIFIED) : numbers[target.id] ?? Int32(AAUDIO_UNSPECIFIED)
      // The stream there is, while it is still on the device it should be.
      if let output, !output.invalidated, output.deviceID == deviceID {
        current = target
        error = nil
        return
      }
      output?.stop()
      output = nil
      do {
        output = try AAudioOutput(deviceID: deviceID, mixer: mixer, sampleRate: sampleRate, cores: cores) {
          [changed] in changed?()
        }
        if relaxed { output?.relax(true) }
        current = target
        error = nil
      } catch {
        current = nil
        self.error = "\(target.name) could not be played through: \(error)"
      }
    }
  }
#endif
