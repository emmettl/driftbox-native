#if os(Linux)
  import CLinuxUI
  import DriftboxGPU
  import DriftboxGPUGLES
  import DriftboxShell
  import Foundation

  @MainActor
  public final class GTKWindow: ShellWindow {
    private var handle: OpaquePointer?
    public private(set) var device: GLESDevice!
    public private(set) var surface: GTKSurface!
    public private(set) var width = 1
    public private(set) var height = 1
    public private(set) var scale: Float = 1
    public private(set) var frames = 0
    public var title = "Driftbox" { didSet { if let handle { db_desktop_title(handle, title) } } }
    public var onEvent: ((ShellEvent) -> Void)?
    public var isEnabled: ((String) -> Bool)?
    public var isChecked: ((String) -> Bool)?
    public var shouldClose: (() -> Bool)?
    public var takesText = false
    public var menuBar: MenuBar? {
      didSet {
        guard menuBar != oldValue, let menuBar, let handle else { return }
        let root = db_menu_new()!
        defer { db_menu_free(root) }
        for menu in menuBar.menus {
          let child = make(menu)
          db_menu_submenu(root, menu.title, child)
          db_menu_free(child)
        }
        db_desktop_menu(handle, root)
      }
    }
    private var ids: [String] = []
    private var numbers: [String: Int] = [:]
    private var states: [Int: (Bool, Bool)] = [:]
    private var held: [Int: KeyEvent] = [:]
    private var frame: (() throws -> Void)?
    private var failure: Error?

    public init() throws {
      var error = [CChar](repeating: 0, count: 512)
      handle = db_desktop_new(
        Unmanaged.passUnretained(self).toOpaque(), drawGTK, inputGTK, commandGTK, closeGTK, dropGTK, &error,
        error.count)
      guard let handle else {
        throw GPUError(
          String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
      }
      guard db_desktop_prepare(handle) != 0 else {
        let message = String(cString: db_desktop_error(handle))
        db_desktop_free(handle)
        self.handle = nil
        throw GPUError(message)
      }
      do {
        device = try GLESDevice(borrowingCurrentContext: ())
        surface = GTKSurface(device: device)
      } catch {
        db_desktop_free(handle)
        self.handle = nil
        throw error
      }
    }
    isolated deinit { dispose() }
    /// Release Desktop before this call, so every GPU object dies while GTK's context is current.
    public func dispose() {
      guard let handle else { return }
      db_desktop_current(handle)
      surface = nil
      device = nil
      db_desktop_free(handle)
      self.handle = nil
    }
    public func makeCurrent() { if let handle { db_desktop_current(handle) } }
    public func run(frame: () throws -> Void) throws {
      guard let handle else { throw GPUError("GTK window is disposed") }
      try withoutActuallyEscaping(frame) { frame in
        self.frame = frame
        defer {
          self.frame = nil
          db_desktop_current(handle)
        }
        db_desktop_run(handle)
        if let failure { throw failure }
        let error = String(cString: db_desktop_error(handle))
        if !error.isEmpty { throw GPUError(error) }
      }
    }
    public func close() { if let handle { db_desktop_close(handle) } }
    public nonisolated func post(_ work: @escaping @Sendable () -> Void) {
      DispatchQueue.main.async(execute: work)
    }

    fileprivate func draw(logicalWidth: Int) {
      guard let handle, let device, let surface else { return }
      do {
        let drawable = device.beginToolkitFrame()
        surface.framebuffer = drawable.framebuffer
        let ratio = Float(drawable.width) / Float(max(1, logicalWidth))
        if width != drawable.width || height != drawable.height || scale != ratio {
          width = drawable.width
          height = drawable.height
          scale = ratio
          onEvent?(.resized(width: width, height: height, scale: scale))
        }
        updateActions()
        try frame?()
        frames += 1
      } catch {
        failure = error
        db_desktop_close(handle)
      }
    }
    private func number(_ id: String) -> Int {
      if let number = numbers[id] { return number }
      let number = ids.count
      ids.append(id)
      numbers[id] = number
      return number
    }
    private func make(_ menu: Menu) -> OpaquePointer {
      let result = db_menu_new()!
      var section = db_menu_new()!
      for item in menu.items {
        switch item {
        case .separator:
          db_menu_section(result, section)
          db_menu_free(section)
          section = db_menu_new()!
        case .submenu(let child):
          let made = make(child)
          db_menu_submenu(section, child.title, made)
          db_menu_free(made)
        case .command(let command):
          let index = number(command.id)
          let label = command.shortcut.map { "\(command.title)    \($0.label)" } ?? command.title
          db_menu_item(section, label, Int32(index))
        }
      }
      db_menu_section(result, section)
      db_menu_free(section)
      return result
    }
    private func updateActions() {
      guard let handle, let menuBar else { return }
      for command in menuBar.commands {
        let index = number(command.id)
        let enabled = isEnabled?(command.id) ?? true
        let checked = isChecked?(command.id) ?? false
        if let old = states[index], old.0 == enabled && old.1 == checked { continue }
        db_desktop_action(handle, Int32(index), enabled ? 1 : 0, checked ? 1 : 0)
        states[index] = (enabled, checked)
      }
    }
    fileprivate func command(_ index: Int) {
      guard ids.indices.contains(index), isEnabled?(ids[index]) ?? true else { return }
      onEvent?(.command(ids[index]))
    }
    fileprivate func input(_ input: db_input) {
      let position = SIMD2(Float(input.x), Float(input.y))
      let modifiers = Modifiers(rawValue: Int(input.modifiers))
      switch input.kind {
      case 1, 2, 3, 8:
        let phase: PointerEvent.Phase =
          input.kind == 1 ? .began : input.kind == 2 ? .moved : input.kind == 3 ? .ended : .cancelled
        onEvent?(
          .pointer(
            PointerEvent(phase: phase, location: position, button: Int(input.button), modifiers: modifiers)))
      case 4:
        onEvent?(
          .scroll(
            ScrollEvent(
              location: position, delta: SIMD2(Float(input.dx), Float(input.dy)), modifiers: modifiers)))
      case 5:
        for var key in held.values {
          key.isDown = false
          key.isRepeat = false
          onEvent?(.key(key))
        }
        held.removeAll()
        onEvent?(.pointer(PointerEvent(phase: .cancelled, location: .zero)))
      case 6:
        guard let key = Self.key(input.key) else { return }
        let code = Int(input.code)
        let event = KeyEvent(key: key, modifiers: modifiers, isRepeat: held[code] != nil)
        let shortcutKey: Key
        if case .character(let character) = key {
          shortcutKey = .character(Character(String(character).lowercased()))
        } else {
          shortcutKey = key
        }
        let typing = takesText && modifiers.subtracting(.shift).isEmpty
        if !typing,
          let command = menuBar?.commands.first(where: { $0.shortcut == Shortcut(shortcutKey, modifiers) })
        {
          if !event.isRepeat, isEnabled?(command.id) ?? true { onEvent?(.command(command.id)) }
          held[code] = event
        } else {
          held[code] = event
          onEvent?(.key(event))
        }
      case 7:
        if var event = held.removeValue(forKey: Int(input.code)) {
          event.isDown = false
          event.isRepeat = false
          onEvent?(.key(event))
        }
      default: break
      }
    }
    private static func key(_ value: Int32) -> Key? {
      switch value {
      case -1: .space
      case -2: .return
      case -3: .escape
      case -4: .tab
      case -5: .backspace
      case -6: .delete
      case -7: .left
      case -8: .right
      case -9: .up
      case -10: .down
      case -11: .home
      case -12: .end
      case -13: .pageUp
      case -14: .pageDown
      case -124 ... -101: .function(Int(-value - 100))
      default: value > 0 ? UnicodeScalar(UInt32(value)).map { .character(Character($0)) } : nil
      }
    }
    /// File portals and GDK drops carry escaped URI lists, not filesystem paths. Reject remote
    /// schemes/hosts because the shared document and WAV readers operate on local files.
    static func localFiles(_ uris: String) -> [URL] {
      uris.split(separator: "\n").compactMap { line in
        guard let url = URL(string: String(line)), url.isFileURL,
          url.host == nil || url.host == "" || url.host == "localhost"
        else { return nil }
        return url
      }
    }

    // Legacy synchronous requests cannot run a GTK dialog without a nested loop. Desktop uses
    // the completion forms below; these conservative answers support older ShellWindow clients.
    public func chooseFile(ofTypes types: [FileType]) -> URL? { nil }
    public func chooseSaveLocation(for type: FileType, name: String) -> URL? { nil }
    public func askToSave(_ name: String) -> SaveAnswer { .cancel }
    public func popUp(
      _ menu: Menu, at point: SIMD2<Float>, isEnabled: (String) -> Bool, isChecked: (String) -> Bool
    ) -> String? { nil }
    private func files(
      _ types: [FileType], save: Bool, multiple: Bool, name: String, completion: @escaping ([URL]) -> Void
    ) {
      guard let handle else {
        completion([])
        return
      }
      let reply = Reply { answer, value in
        completion(answer == 0 ? [] : Self.localFiles(value))
      }
      db_desktop_files(
        handle, save ? 1 : 0, multiple ? 1 : 0, types.flatMap(\.extensions).joined(separator: ";"), name,
        Unmanaged.passRetained(reply).toOpaque(), replyGTK)
    }
    public func chooseFile(ofTypes types: [FileType], completion: @escaping (URL?) -> Void) {
      files(types, save: false, multiple: false, name: "") { completion($0.first) }
    }
    public func chooseFiles(ofTypes types: [FileType], completion: @escaping ([URL]) -> Void) {
      files(types, save: false, multiple: true, name: "", completion: completion)
    }
    public func chooseSaveLocation(for type: FileType, name: String, completion: @escaping (URL?) -> Void) {
      let filename = type.extensions.first.map { name.hasSuffix(".\($0)") ? name : "\(name).\($0)" } ?? name
      files([type], save: true, multiple: false, name: filename) { completion($0.first) }
    }
    public func askToSave(_ name: String, completion: @escaping (SaveAnswer) -> Void) {
      guard let handle else {
        completion(.cancel)
        return
      }
      let reply = Reply { answer, _ in completion(answer == 1 ? .save : answer == 2 ? .discard : .cancel) }
      db_desktop_save_question(handle, name, Unmanaged.passRetained(reply).toOpaque(), replyGTK)
    }
    public func popUp(
      _ menu: Menu, at point: SIMD2<Float>, isEnabled: @escaping (String) -> Bool,
      isChecked: @escaping (String) -> Bool, completion: @escaping (String?) -> Void
    ) {
      guard let handle else {
        completion(nil)
        return
      }
      let model = make(menu)
      defer { db_menu_free(model) }
      for command in menu.commands {
        let index = number(command.id)
        db_desktop_action(handle, Int32(index), isEnabled(command.id) ? 1 : 0, isChecked(command.id) ? 1 : 0)
        states.removeValue(forKey: index)
      }
      let reply = Reply { [weak self] answer, _ in
        guard answer > 0, let self, self.ids.indices.contains(answer - 1) else {
          completion(nil)
          return
        }
        completion(self.ids[answer - 1])
      }
      db_desktop_popup(
        handle, model, Double(point.x), Double(point.y), Unmanaged.passRetained(reply).toOpaque(), replyGTK)
    }
  }
  @MainActor private final class Reply {
    let completion: (Int, String) -> Void
    init(_ completion: @escaping (Int, String) -> Void) { self.completion = completion }
  }
  private func replyGTK(context: UnsafeMutableRawPointer?, answer: Int32, value: UnsafePointer<CChar>?) {
    guard let context else { return }
    let reply = Unmanaged<Reply>.fromOpaque(context).takeRetainedValue()
    let string = value.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated { reply.completion(Int(answer), string) }
  }
  private func drawGTK(context: UnsafeMutableRawPointer?, width: Int32, height: Int32, scale: Int32) {
    guard let context else { return }
    let window = Unmanaged<GTKWindow>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { window.draw(logicalWidth: Int(width)) }
  }
  private func inputGTK(context: UnsafeMutableRawPointer?, input: UnsafePointer<db_input>?) {
    guard let context, let event = input?.pointee else { return }
    let window = Unmanaged<GTKWindow>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { window.input(event) }
  }
  private func commandGTK(context: UnsafeMutableRawPointer?, command: Int32) {
    guard let context else { return }
    let window = Unmanaged<GTKWindow>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { window.command(Int(command)) }
  }
  private func dropGTK(context: UnsafeMutableRawPointer?, uris: UnsafePointer<CChar>?, x: Double, y: Double) {
    guard let context, let uris else { return }
    let window = Unmanaged<GTKWindow>.fromOpaque(context).takeUnretainedValue()
    let text = String(cString: uris)
    MainActor.assumeIsolated {
      let files = GTKWindow.localFiles(text)
      if !files.isEmpty { window.onEvent?(.dropped(files, at: SIMD2(Float(x), Float(y)))) }
    }
  }
  private func closeGTK(context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 1 }
    let window = Unmanaged<GTKWindow>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated { window.shouldClose?() == false ? 0 : 1 }
  }
#endif
