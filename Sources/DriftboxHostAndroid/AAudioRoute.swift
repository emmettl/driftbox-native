#if os(Android)
  import CAAudio
  import DriftboxHost

  /// Where the sound goes on Android, kept there: AAudio's `AudioRouting`.
  ///
  /// One device for now, the system's, which follows headphones and Bluetooth as Android routes
  /// them. AAudio plays through a device by number but cannot list them: that is Java's
  /// `AudioManager`, which needs the app around it, and arrives with the app. Until then a choice
  /// of device is remembered and the system's is played through, as it is for any choice that is
  /// not there.
  ///
  /// A stream whose device goes away ends, and says so on a thread of its own; `apply` makes the
  /// next one. It works out where the sound should be going from scratch, as `WASAPIRoute` does,
  /// so it does not matter what set it off.
  @MainActor
  public final class AAudioRoute: AudioRouting {
    /// The system's output, which is the only one there is until the app can list them.
    public static let system = AudioDevice(id: "system", name: "the phone's output")

    public var chosen: String? {
      didSet { if chosen != oldValue { apply() } }
    }
    public private(set) var devices: [AudioDevice] = [AAudioRoute.system]
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

    /// Lets the stream's buffer out by a burst if it has underrun since last asked, and says so
    /// through `onChange`. Call it now and then; once a second is plenty.
    public func tune() {
      if output?.tune() == true { onChange?() }
    }

    /// Point a stream at the device it should be playing through, and make sure it is.
    public func apply() {
      defer { onChange?() }
      guard let target = AudioDevices.pick(chosen: chosen, among: devices, systemDefault: systemDefault)
      else {
        output?.stop()
        output = nil
        current = nil
        error = "There is nothing to play through."
        return
      }
      if let output, !output.invalidated {
        current = target
        error = nil
        return
      }
      output?.stop()
      output = nil
      do {
        output = try AAudioOutput(
          deviceID: target == Self.system
            ? Int32(AAUDIO_UNSPECIFIED) : Int32(target.id) ?? Int32(AAUDIO_UNSPECIFIED),
          mixer: mixer, sampleRate: sampleRate, cores: cores
        ) { [changed] in changed?() }
        current = target
        error = nil
      } catch {
        current = nil
        self.error = "\(target.name) could not be played through: \(error)"
      }
    }
  }
#endif
