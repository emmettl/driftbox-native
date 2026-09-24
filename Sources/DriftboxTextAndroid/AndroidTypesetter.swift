#if os(Android)
  import Android
  import DriftboxText

  /// Type on Android: Android's own text stack, reached through the app's `app.driftbox.Type`, since
  /// the NDK has fonts to find but nothing to shape or draw them with. Java's `TextRunShaper` sets a
  /// line — Minikin and HarfBuzz underneath, so kerned from the font's own tables as a browser's
  /// canvas kerns it — and `Canvas.drawGlyphs` draws a glyph into an alpha bitmap, antialiased and
  /// placed to a fraction of a pixel. Both are Android 12's, so there is no typesetter before it.
  ///
  /// A family is found by the names `fonts.xml` gives Android's families, which include the web's
  /// usual ones as aliases: Arial and Helvetica are Roboto, Times and Georgia Noto Serif. When none
  /// of those asked for is there, a line is set in `fallback`.
  ///
  /// It may be called on any thread, as it is on the render thread: a thread Java did not start is
  /// attached to Java on its first call, and let go of again as it ends. That is what makes it
  /// sendable: what Swift holds never changes, and Java's side sets and draws behind one lock.
  public final class AndroidTypesetter: Typesetter, @unchecked Sendable {
    /// The family used when none of those asked for is one Android has.
    public static let fallback = "sans-serif"

    private let vm: UnsafeMutablePointer<JavaVM?>
    private let type: jclass
    private let lineMethod: jmethodID
    private let coverageMethod: jmethodID
    private let stringType: jclass

    /// A typesetter through the app's own Java, found through `env` — which must be a thread Java
    /// started, from a call the app made, since only there does a class lookup see the app's
    /// classes. Nil before Android 12, or without the app.
    public init?(env: UnsafeMutablePointer<JNIEnv?>) {
      guard android_get_device_api_level() >= 31, let jni = env.pointee?.pointee else { return nil }
      var vm: UnsafeMutablePointer<JavaVM?>?
      guard jni.GetJavaVM!(env, &vm) == JNI_OK, let vm,
        let local = jni.FindClass!(env, "app/driftbox/Type"),
        let string = jni.FindClass!(env, "java/lang/String")
      else {
        Self.clear(env)
        return nil
      }
      defer {
        jni.DeleteLocalRef!(env, local)
        jni.DeleteLocalRef!(env, string)
      }
      guard
        let line = jni.GetStaticMethodID!(env, local, "line", "(Ljava/lang/String;[Ljava/lang/String;IF)[F"),
        let coverage = jni.GetStaticMethodID!(env, local, "coverage", "(IIFF)[B"),
        let type = jni.NewGlobalRef!(env, local), let stringType = jni.NewGlobalRef!(env, string)
      else {
        Self.clear(env)
        return nil
      }
      self.vm = vm
      self.type = type
      self.stringType = stringType
      lineMethod = line
      coverageMethod = coverage
      Attached.prepare()
    }

    deinit {
      guard let env = Attached.env(vm), let jni = env.pointee?.pointee else { return }
      jni.DeleteGlobalRef!(env, type)
      jni.DeleteGlobalRef!(env, stringType)
    }

    public func line(_ text: String, font request: FontRequest) -> TextLine {
      let empty = TextLine(glyphs: [], width: 0, ascent: 0, descent: 0, family: Self.fallback)
      guard let env = Attached.env(vm), let jni = env.pointee?.pointee,
        jni.PushLocalFrame!(env, Int32(request.families.count + 4)) == JNI_OK
      else { return empty }
      defer { _ = jni.PopLocalFrame!(env, nil) }

      guard let families = jni.NewObjectArray!(env, Int32(request.families.count), stringType, nil) else {
        Self.clear(env)
        return empty
      }
      for (index, family) in request.families.enumerated() {
        jni.SetObjectArrayElement!(env, families, Int32(index), jni.NewStringUTF!(env, family))
      }
      var arguments = [
        jvalue(l: jni.NewStringUTF!(env, text)), jvalue(l: families), jvalue(i: Int32(request.weight)),
        jvalue(f: request.size),
      ]
      let result = jni.CallStaticObjectMethodA!(env, type, lineMethod, &arguments)
      guard !Self.clear(env), let result else { return empty }
      let count = Int(jni.GetArrayLength!(env, result))
      guard count >= 4 else { return empty }
      var numbers = [Float](repeating: 0, count: count)
      jni.GetFloatArrayRegion!(env, result, 0, Int32(count), &numbers)

      let chosen = Int(numbers[3])
      var glyphs: [PlacedGlyph] = []
      glyphs.reserveCapacity((count - 4) / 4)
      for at in stride(from: 4, to: count - 3, by: 4) {
        glyphs.append(
          PlacedGlyph(
            glyph: Glyph(face: Int(numbers[at]), index: UInt16(numbers[at + 1]), size: request.size),
            origin: SIMD2(numbers[at + 2], numbers[at + 3])))
      }
      return TextLine(
        glyphs: glyphs, width: numbers[0], ascent: numbers[1], descent: numbers[2],
        family: chosen >= 0 && chosen < request.families.count ? request.families[chosen] : Self.fallback)
    }

    public func coverage(_ glyph: Glyph, offset: Float) -> GlyphCoverage? {
      guard let env = Attached.env(vm), let jni = env.pointee?.pointee,
        jni.PushLocalFrame!(env, 4) == JNI_OK
      else { return nil }
      defer { _ = jni.PopLocalFrame!(env, nil) }

      var arguments = [
        jvalue(i: Int32(glyph.face)), jvalue(i: Int32(glyph.index)), jvalue(f: glyph.size), jvalue(f: offset),
      ]
      let result = jni.CallStaticObjectMethodA!(env, type, coverageMethod, &arguments)
      guard !Self.clear(env), let result else { return nil }
      let count = Int(jni.GetArrayLength!(env, result))
      guard count >= 16 else { return nil }
      var bytes = [UInt8](repeating: 0, count: count)
      bytes.withUnsafeMutableBufferPointer { out in
        out.baseAddress!.withMemoryRebound(to: jbyte.self, capacity: count) {
          jni.GetByteArrayRegion!(env, result, 0, Int32(count), $0)
        }
      }
      func int(_ at: Int) -> Int {
        Int(
          Int32(
            bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
              | UInt32(bytes[at + 3]) << 24))
      }
      let width = int(0)
      let height = int(4)
      guard width > 0, height > 0, count == 16 + width * height else { return nil }
      return GlyphCoverage(
        width: width, height: height, left: int(8), top: int(12), bytes: Array(bytes[16...]))
    }

    /// Whether Java threw, which is said to the log and then cleared, since a thread with an
    /// exception pending cannot call Java again.
    @discardableResult
    private static func clear(_ env: UnsafeMutablePointer<JNIEnv?>) -> Bool {
      guard let jni = env.pointee?.pointee, jni.ExceptionCheck!(env) != 0 else { return false }
      jni.ExceptionDescribe!(env)
      jni.ExceptionClear!(env)
      return true
    }
  }

  /// A thread's hold on Java: taken on its first call, and let go of by the thread's own end, as
  /// Android wants of a thread it did not start — one that ends still holding on aborts the app.
  enum Attached {
    nonisolated(unsafe) private static var key = pthread_key_t()
    private static let made: Void = {
      // The value kept for a thread is the Java VM itself, so the destructor has what it needs.
      pthread_key_create(&key) { value in
        guard let value else { return }
        let vm = value.assumingMemoryBound(to: JavaVM?.self)
        _ = vm.pointee?.pointee.DetachCurrentThread!(vm)
      }
    }()

    /// The key made, on the thread Java started, before any other needs it.
    static func prepare() { _ = made }

    /// This thread's environment, attaching it to Java if Java did not start it.
    static func env(_ vm: UnsafeMutablePointer<JavaVM?>) -> UnsafeMutablePointer<JNIEnv?>? {
      guard let invoke = vm.pointee?.pointee else { return nil }
      var raw: UnsafeMutableRawPointer?
      if invoke.GetEnv!(vm, &raw, JNI_VERSION_1_6) == JNI_OK, let raw {
        return raw.assumingMemoryBound(to: JNIEnv?.self)
      }
      var env: UnsafeMutablePointer<JNIEnv?>?
      guard invoke.AttachCurrentThread!(vm, &env, nil) == JNI_OK, let env else { return nil }
      _ = made
      pthread_setspecific(key, UnsafeRawPointer(vm))
      return env
    }
  }
#endif
