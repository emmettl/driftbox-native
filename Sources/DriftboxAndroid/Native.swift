#if os(Android)
  import CAMidi
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
