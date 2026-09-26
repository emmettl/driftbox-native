#if os(Linux)
  import DriftboxGTK
  import DriftboxShell

  /// Run as part of --smoke-test, on the executable's main thread. Swift Testing already owns
  /// the dispatch main loop, so GTK's eventfd integration cannot be initialized in that runner.
  @MainActor func checkNativeDialogCallbacks() throws {
    for present in [false, true] {
      for request in ["question", "open", "multiple", "save", "folder"] {
        let window = try GTKWindow()
        defer { window.dispose() }
        let shell: any ShellWindow = window
        let type = FileType(name: "Driftbox Song", extensions: ["driftbox"])
        var responses = 0
        var cancelled = false
        switch request {
        case "question":
          shell.askToSave("Unsaved") { answer in
            responses += 1
            cancelled = answer == .cancel
          }
        case "open":
          shell.chooseFile(ofTypes: [type]) { url in
            responses += 1
            cancelled = url == nil
          }
        case "multiple":
          shell.chooseFiles(ofTypes: [type]) { urls in
            responses += 1
            cancelled = urls.isEmpty
          }
        case "folder":
          shell.chooseFolder(title: "Export Stems", button: "Export Here") { url in
            responses += 1
            cancelled = url == nil
          }
        default:
          shell.chooseSaveLocation(for: type, name: "Unsaved") { url in
            responses += 1
            cancelled = url == nil
          }
        }
        guard responses == 0 else {
          throw DialogCheckFailure("\(request) returned synchronously instead of waiting for GTK")
        }
        if present {
          // Exercise a presented chooser separately from cancellation before the first GTK turn.
          // GTK's standalone already-loading chooser teardown bug remains a toolkit diagnostic.
          let close = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(250))
            window.close()
          }
          defer { close.cancel() }
          try window.run(frame: {})
        }
        window.dispose()
        guard responses == 1, cancelled else {
          throw DialogCheckFailure("\(request) did not cancel exactly once on disposal")
        }
        window.dispose()
        guard responses == 1 else {
          throw DialogCheckFailure("\(request) completed again on repeated disposal")
        }
      }
    }
    // Notices share the live shell but never own a document request's callback.
    let notices = try GTKWindow()
    notices.tell("A document could not be opened — 100% <literal> text")
    notices.tell("A second failure is queued")
    let closeNotices = Task { @MainActor in
      try await Task.sleep(for: .milliseconds(250))
      notices.close()
    }
    defer {
      closeNotices.cancel()
      notices.dispose()
    }
    try notices.run(frame: {})
    notices.dispose()
    print(
      "Native dialogs: five deferred requests cancelled exactly once; queued notices disposed; early cancellations passed"
    )
  }

  private struct DialogCheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }
#endif
