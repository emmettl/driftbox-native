#if os(Linux)
  import DriftboxGTK
  import DriftboxShell

  /// Run as part of --smoke-test, on the executable's main thread. Swift Testing already owns
  /// the dispatch main loop, so GTK's eventfd integration cannot be initialized in that runner.
  @MainActor func checkNativeDialogCallbacks() throws {
    for request in ["question", "open", "multiple", "save"] {
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
      default:
        shell.chooseSaveLocation(for: type, name: "Unsaved") { url in
          responses += 1
          cancelled = url == nil
        }
      }
      guard responses == 0 else {
        throw DialogCheckFailure("\(request) returned synchronously instead of waiting for GTK")
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
    print("Native dialogs: four deferred requests cancelled exactly once")
  }

  private struct DialogCheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }
#endif
