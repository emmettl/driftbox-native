#if os(Windows)
  import Foundation
  import WinSDK

  /// What WinMM calls its devices, and a timer that notices when the list of them changes.
  ///
  /// WinMM numbers devices by their place in a list that shifts whenever one comes or goes, and
  /// tells nobody when it does. So a device is known by its name, as the Mac remembers them too, and
  /// the list is read again every two seconds; a change is when ports are opened again.
  enum WinMM {
    static func inputNames() -> [String] {
      (0..<midiInGetNumDevs()).map { index in
        var caps = MIDIINCAPSW()
        guard
          midiInGetDevCapsW(UINT_PTR(index), &caps, UINT(MemoryLayout<MIDIINCAPSW>.size)) == MMSYSERR_NOERROR
        else { return "MIDI \(index)" }
        return name(caps.szPname)
      }
    }

    static func outputNames() -> [String] {
      (0..<midiOutGetNumDevs()).map { index in
        var caps = MIDIOUTCAPSW()
        guard
          midiOutGetDevCapsW(UINT_PTR(index), &caps, UINT(MemoryLayout<MIDIOUTCAPSW>.size))
            == MMSYSERR_NOERROR
        else { return "MIDI \(index)" }
        return name(caps.szPname)
      }
    }

    /// A fixed-size wide string out of a capabilities struct.
    static func name<T>(_ tuple: T) -> String {
      withUnsafeBytes(of: tuple) { bytes in
        let wide = bytes.bindMemory(to: UInt16.self)
        let end = wide.firstIndex(of: 0) ?? wide.count
        return String(decoding: wide[..<end], as: UTF16.self)
      }
    }

    /// Calls `changed` on a background queue whenever `list` reads differently from last time.
    final class Watch: @unchecked Sendable {
      private let timer: DispatchSourceTimer

      init(list: @escaping @Sendable () -> [String], changed: @escaping @Sendable ([String]) -> Void) {
        let queue = DispatchQueue(label: "Driftbox MIDI devices")
        timer = DispatchSource.makeTimerSource(queue: queue)
        var last = list()
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
          let now = list()
          guard now != last else { return }
          last = now
          changed(now)
        }
        timer.resume()
      }

      deinit { timer.cancel() }
    }
  }
#endif
