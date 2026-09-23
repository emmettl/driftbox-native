#if os(Android)
  import CAMidi
  import CGLES
  import DriftboxHostAndroid

  // What `app.driftbox.Native` in `android/` declares, one function each, and everything this app
  // shares between them. The names are JNI's: `Java_`, the class, the method.

  /// The MIDI devices Java has opened, for everything in the app to use.
  let midiDevices = AMidiDevices()

  @_cdecl("Java_app_driftbox_Native_deviceAdded")
  public func nativeDeviceAdded(
    _ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ id: jint, _ name: jstring?, _ device: jobject?
  ) {
    guard let device else { return }
    midiDevices.add(java: device, env: env, id: id, name: env.string(name))
  }

  @_cdecl("Java_app_driftbox_Native_deviceRemoved")
  public func nativeDeviceRemoved(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ id: jint) {
    midiDevices.remove(id: id)
  }

  @_cdecl("Java_app_driftbox_Native_midiLoopback")
  public func nativeMIDILoopback(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?) -> jstring? {
    env.java(MIDILoopback.run(devices: midiDevices))
  }

  @_cdecl("Java_app_driftbox_Native_gpuCheck")
  public func nativeGPUCheck(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?) -> jstring? {
    env.java(GPUCheck.run())
  }

  // Pulse on the screen: all of these on Java's main thread, which is the main actor's.

  /// The song playing and being drawn, if one is.
  @MainActor var stage: PulseStage?
  /// The window it is drawn in, held from Java's surface until the render thread has let go of it.
  @MainActor var window: OpaquePointer?

  @_cdecl("Java_app_driftbox_Native_start")
  public func nativeStart(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ json: jstring?) -> jboolean
  {
    let text = env.string(json)
    return MainActor.assumeIsolated {
      stage?.stop()
      stage = PulseStage(json: text)
      return stage == nil ? jboolean(JNI_FALSE) : jboolean(JNI_TRUE)
    }
  }

  @_cdecl("Java_app_driftbox_Native_stop")
  public func nativeStop(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?) {
    MainActor.assumeIsolated {
      stage?.stop()
      stage = nil
      if let window { ANativeWindow_release(window) }
      window = nil
    }
  }

  @_cdecl("Java_app_driftbox_Native_setShown")
  public func nativeSetShown(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ shown: jboolean) {
    MainActor.assumeIsolated { stage?.setShown(shown != 0) }
  }

  @_cdecl("Java_app_driftbox_Native_surfaceChanged")
  public func nativeSurfaceChanged(
    _ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ surface: jobject?, _ width: jint, _ height: jint
  ) {
    // Across to the main actor as its address, which is all a window is to Swift.
    guard let surface, let made = ANativeWindow_fromSurface(env, surface) else { return }
    let address = Int(bitPattern: made)
    MainActor.assumeIsolated {
      let next = OpaquePointer(bitPattern: address)!
      guard let stage else {
        ANativeWindow_release(next)
        return
      }
      stage.show(window: next, width: Int(width), height: Int(height))
      if let window { ANativeWindow_release(window) }
      window = next
    }
  }

  @_cdecl("Java_app_driftbox_Native_surfaceDestroyed")
  public func nativeSurfaceDestroyed(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?) {
    MainActor.assumeIsolated {
      stage?.hide()
      if let window { ANativeWindow_release(window) }
      window = nil
    }
  }

  @_cdecl("Java_app_driftbox_Native_touch")
  public func nativeTouch(
    _ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ x: jfloat, _ y: jfloat, _ down: jboolean
  ) {
    MainActor.assumeIsolated { stage?.touch(x: x, y: y, down: down != 0) }
  }

  @_cdecl("Java_app_driftbox_Native_tick")
  public func nativeTick(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?) -> jstring? {
    env.java(MainActor.assumeIsolated { stage?.tick() ?? "nothing playing" })
  }

  extension UnsafeMutablePointer where Pointee == JNIEnv? {
    /// A Java string as a Swift one; empty for null.
    func string(_ java: jstring?) -> String {
      guard let java, let functions = pointee?.pointee,
        let chars = functions.GetStringUTFChars(self, java, nil)
      else { return "" }
      defer { functions.ReleaseStringUTFChars(self, java, chars) }
      return String(cString: chars)
    }

    /// A Swift string as a Java one.
    func java(_ string: String) -> jstring? {
      pointee?.pointee.NewStringUTF(self, string)
    }
  }
#endif
