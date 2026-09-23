#if os(Android)
  import Android

  /// What the render thread needs from Android beyond AAudio, looked up at run time.
  ///
  /// `sched_setaffinity` is declared only under `_GNU_SOURCE`, which a Swift module cannot set for
  /// Bionic's headers, and the performance hint API arrived in Android 13, after the API level
  /// Driftbox builds for. Both are in the libraries of every phone that has them, so each is found
  /// by name there; one that is missing is nil, and what it would have done is not done.
  enum Bionic {
    typealias SetAffinity = @convention(c) (pid_t, Int, UnsafeRawPointer) -> Int32
    typealias HintManager = @convention(c) () -> OpaquePointer?
    typealias CreateHintSession =
      @convention(c) (OpaquePointer, UnsafePointer<Int32>, Int, Int64) -> OpaquePointer?
    typealias ReportWork = @convention(c) (OpaquePointer, Int64) -> Int32
    typealias CloseHintSession = @convention(c) (OpaquePointer) -> Void

    static let setAffinity: SetAffinity? = symbol("sched_setaffinity", in: "libc.so")
    static let hintManager: HintManager? = symbol("APerformanceHint_getManager", in: "libandroid.so")
    static let createHintSession: CreateHintSession? = symbol(
      "APerformanceHint_createSession", in: "libandroid.so")
    static let reportWork: ReportWork? = symbol(
      "APerformanceHint_reportActualWorkDuration", in: "libandroid.so")
    static let closeHintSession: CloseHintSession? = symbol(
      "APerformanceHint_closeSession", in: "libandroid.so")

    private static func symbol<Function>(_ name: String, in library: String) -> Function? {
      guard let handle = dlopen(library, RTLD_NOW), let address = dlsym(handle, name) else { return nil }
      return unsafeBitCast(address, to: Function.self)
    }

    /// Each core's highest frequency, in kHz, in core order; 0 for one that will not say.
    static func maximumFrequencies() -> [Int] {
      var frequencies: [Int] = []
      while frequencies.count < 1024 {
        let core = frequencies.count
        guard access("/sys/devices/system/cpu/cpu\(core)", F_OK) == 0 else { break }
        frequencies.append(readNumber("/sys/devices/system/cpu/cpu\(core)/cpufreq/cpuinfo_max_freq") ?? 0)
      }
      return frequencies
    }

    private static func readNumber(_ path: String) -> Int? {
      guard let file = fopen(path, "r") else { return nil }
      defer { fclose(file) }
      var bytes = [CChar](repeating: 0, count: 32)
      guard fgets(&bytes, Int32(bytes.count), file) != nil else { return nil }
      let text = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return Int(text.filter(\.isNumber))
    }
  }
#endif
