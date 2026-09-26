#if os(Windows)
  import WinSDK

  /// The displays attached, as a person knows them: by the name the monitor gives itself, or
  /// "Built-in Display" for a laptop's own panel, whose own name is a part code if it has one; the
  /// main one first, the rest from left to right, and a name that two share numbered.
  enum Win32Displays {
    struct Display: Equatable {
      var name: String
      /// Windows' own name for it, `\\.\DISPLAY2`, which a window's monitor is matched by.
      var device: String
      /// All of it, and the part of it not under the taskbar, in pixels on the virtual screen.
      var bounds: RECT
      var work: RECT
      var isMain: Bool

      static func == (a: Display, b: Display) -> Bool { a.device == b.device && a.name == b.name }
    }

    /// Every display attached, named.
    static func all() -> [Display] {
      let names = friendlyNames()
      final class Found {
        var monitors: [(device: String, bounds: RECT, work: RECT, isMain: Bool)] = []
      }
      let found = Found()
      let context = LPARAM(Int(bitPattern: Unmanaged.passUnretained(found).toOpaque()))
      EnumDisplayMonitors(
        nil, nil,
        { monitor, _, _, context in
          guard let monitor, let pointer = UnsafeRawPointer(bitPattern: Int(context)) else { return true }
          let found = Unmanaged<Found>.fromOpaque(pointer).takeUnretainedValue()
          var info = MONITORINFOEXW()
          info.cbSize = DWORD(MemoryLayout<MONITORINFOEXW>.size)
          let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: MONITORINFO.self, capacity: 1) { GetMonitorInfoW(monitor, $0) }
          }
          if read {
            found.monitors.append(
              (
                Win32Displays.string(info.szDevice), info.rcMonitor, info.rcWork,
                info.dwFlags & DWORD(MONITORINFOF_PRIMARY) != 0
              ))
          }
          return true
        }, context)
      let ordered = found.monitors.sorted {
        $0.isMain != $1.isMain ? $0.isMain : $0.bounds.left < $1.bounds.left
      }
      var used: [String: Int] = [:]
      return ordered.enumerated().map { index, monitor in
        let base = names[monitor.device] ?? "Display \(index + 1)"
        used[base, default: 0] += 1
        let name = used[base]! > 1 ? "\(base) (\(used[base]!))" : base
        return Display(
          name: name, device: monitor.device, bounds: monitor.bounds, work: monitor.work,
          isMain: monitor.isMain)
      }
    }

    /// The display the window is mostly on.
    static func display(of window: HWND) -> Display? {
      guard let monitor = MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)) else { return nil }
      var info = MONITORINFOEXW()
      info.cbSize = DWORD(MemoryLayout<MONITORINFOEXW>.size)
      let read = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: MONITORINFO.self, capacity: 1) { GetMonitorInfoW(monitor, $0) }
      }
      guard read else { return nil }
      let device = string(info.szDevice)
      return all().first { $0.device == device }
    }

    /// Each active display's monitor name, by the device Windows calls it: from the display
    /// configuration, which knows what the monitor says it is, where the older calls know only
    /// "Generic PnP Monitor".
    static func friendlyNames() -> [String: String] {
      var pathCount: UINT32 = 0
      var modeCount: UINT32 = 0
      let flags = UINT32(QDC_ONLY_ACTIVE_PATHS)
      guard GetDisplayConfigBufferSizes(flags, &pathCount, &modeCount) == ERROR_SUCCESS else { return [:] }
      var paths = [DISPLAYCONFIG_PATH_INFO](repeating: DISPLAYCONFIG_PATH_INFO(), count: Int(pathCount))
      var modes = [DISPLAYCONFIG_MODE_INFO](repeating: DISPLAYCONFIG_MODE_INFO(), count: Int(modeCount))
      guard QueryDisplayConfig(flags, &pathCount, &paths, &modeCount, &modes, nil) == ERROR_SUCCESS else {
        return [:]
      }
      var names: [String: String] = [:]
      for path in paths.prefix(Int(pathCount)) {
        var source = DISPLAYCONFIG_SOURCE_DEVICE_NAME()
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
        source.header.size = UINT32(MemoryLayout<DISPLAYCONFIG_SOURCE_DEVICE_NAME>.size)
        source.header.adapterId = path.sourceInfo.adapterId
        source.header.id = path.sourceInfo.id
        var target = DISPLAYCONFIG_TARGET_DEVICE_NAME()
        target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        target.header.size = UINT32(MemoryLayout<DISPLAYCONFIG_TARGET_DEVICE_NAME>.size)
        target.header.adapterId = path.targetInfo.adapterId
        target.header.id = path.targetInfo.id
        // Each asked for whole, through its header: the call fills in what follows it.
        let sourceRead = withUnsafeMutablePointer(to: &source) {
          $0.withMemoryRebound(to: DISPLAYCONFIG_DEVICE_INFO_HEADER.self, capacity: 1) {
            DisplayConfigGetDeviceInfo($0)
          }
        }
        let targetRead = withUnsafeMutablePointer(to: &target) {
          $0.withMemoryRebound(to: DISPLAYCONFIG_DEVICE_INFO_HEADER.self, capacity: 1) {
            DisplayConfigGetDeviceInfo($0)
          }
        }
        guard sourceRead == ERROR_SUCCESS else { continue }
        let device = string(source.viewGdiDeviceName)
        let monitor = targetRead == ERROR_SUCCESS ? string(target.monitorFriendlyDeviceName) : ""
        let builtIn = [
          DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL, DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED,
          DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED,
        ].contains(target.outputTechnology)
        // A laptop's own panel by what it is: its own name is a maker's part code, when it has one.
        if builtIn {
          names[device] = "Built-in Display"
        } else if !monitor.isEmpty {
          names[device] = monitor
        }
      }
      return names
    }

    /// A fixed array of wide characters, as C imports one, up to its end.
    static func string<Field>(_ field: Field) -> String {
      withUnsafeBytes(of: field) { raw in
        let units = raw.bindMemory(to: UInt16.self)
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
      }
    }
  }
#endif
