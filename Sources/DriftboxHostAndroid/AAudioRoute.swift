#if os(Android)
  import CAAudio
  import DriftboxHost

  /// Where the sound goes on Android, kept there: AAudio's `AudioRouting`.
  ///
  /// The system's output, which follows headphones and Bluetooth as Android routes them, unless a
  /// device is chosen. AAudio plays through a device by number but cannot list them: that is
  /// Java's `AudioManager`, which the app asks and hands on through `update(outputs:)`. A device's
  /// number is Android's for as long as it is plugged in, so a choice is remembered by a name for
  /// good that the app makes of it instead, and the number looked up when it is played through.
  /// A choice that is not there is remembered, and the system's played through until it is back.
  ///
  /// A stream whose device goes away ends, and says so on a thread of its own; `apply` makes the
  /// next one. It works out where the sound should be going from scratch, as `WASAPIRoute` does,
  /// so it does not matter what set it off.
  @MainActor
  public final class AAudioRoute: AudioRouting {
    /// The system's output: wherever Android is sending sound.
    public static let system = AudioDevice(id: "system", name: "the phone's output")

    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    public private(set) var devices: [AudioDevice] = []
    public private(set) var current: AudioDevice?
    public let systemDefault: AudioDevice? = AAudioRoute.system
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    public let sampleRate: Double
    public var latency: Double { output?.latency ?? 0 }

    /// Underruns since the stream started.
    public var xruns: Int { output?.xruns ?? 0 }

    /// What the stream is, in words: sharing, burst, buffer, and what the render thread was given.
    public var details: String? {
      guard let shape = output?.shape else { return nil }
      let tenths = Int((Double(shape.framesPerBurst) / Double(shape.sampleRate) * 10_000).rounded())
      let cores =
        shape.cores.isEmpty ? "any core" : "cores \(shape.cores.map(String.init).joined(separator: ","))"
      return
        "\(shape.exclusive ? "exclusive" : "shared"), \(shape.sampleRate) Hz, "
        + "bursts of \(shape.framesPerBurst) frames (\(tenths / 10).\(tenths % 10)ms), "
        + "buffer of \(shape.bufferFrames), render thread on \(cores), "
        + (shape.hinted ? "performance hint on" : "no performance hint")
    }

    private let mixer = Mixer()
    private var output: AAudioOutput?
    /// Each listed device's number, by its name for good.
    private var numbers: [String: Int32] = [:]
    /// The number of the device the stream was opened on: AAudio's unspecified for the system's.
    private var opened: Int32?
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

    /// The outputs the phone has now, as Java's `AudioManager` lists them: each a name for good, the
    /// number AAudio plays it by, and what it is called.
    public func update(outputs: [(id: String, number: Int32, name: String)]) {
      let listed = outputs.map { AudioDevice(id: $0.id, name: $0.name) }
      let numbered = Dictionary(outputs.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
      guard listed != devices || numbered != numbers else { return }
      devices = listed
      numbers = numbered
      apply()
    }

    /// The number AAudio plays `device` by: unspecified, which is the system's routing, for the
    /// system's output or a device no longer listed.
    private func number(for device: AudioDevice) -> Int32 {
      device == Self.system ? Int32(AAUDIO_UNSPECIFIED) : numbers[device.id] ?? Int32(AAUDIO_UNSPECIFIED)
    }

    public func apply() {
      defer { onChange?() }
      guard !suspended else {
        output?.stop()
        output = nil
        opened = nil
        current = nil
        error = nil
        return
      }
      guard let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      else {
        output?.stop()
        output = nil
        opened = nil
        current = nil
        error = "There is nothing to play through."
        return
      }
      let deviceID = number(for: target)
      // The stream playing on is kept while it is on the device it should be: another chosen, or
      // the chosen one come back or gone, and it is opened again where the sound should go.
      if let output, !output.invalidated, opened == deviceID {
        current = target
        error = nil
        return
      }
      output?.stop()
      output = nil
      opened = nil
      do {
        output = try AAudioOutput(
          deviceID: deviceID, mixer: mixer, sampleRate: sampleRate, cores: cores
        ) { [changed] in changed?() }
        opened = deviceID
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
