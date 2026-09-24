#if canImport(SwiftUI) && canImport(AVFoundation)
  import AppKit
  import DriftboxDocument
  import DriftboxEngine
  import DriftboxSession
  import SwiftUI
  import UniformTypeIdentifiers

  extension UTType {
    /// The song document's own type, `.driftbox`, declared in the bundle's Info.plist so that the
    /// Finder knows which application owns one. A loose build has no plist at all, so this falls
    /// back to the extension alone, and past that to what a song is underneath, which is JSON.
    static let song =
      UTType("app.driftbox.native.song")
      ?? UTType(filenameExtension: SongFile.fileExtension, conformingTo: .json) ?? .json
  }

  /// What the File menu means, once: the panels, the exports, and what Save does when the song
  /// already has a file. The menu and the toolbar both call these rather than each holding their
  /// own copy, so the two cannot come to mean different things.
  ///
  /// AppKit, and deliberately not on `Session`: a panel is a Mac, and `Session` is meant to survive
  /// the move to a platform that has none.
  @MainActor
  public struct SongFiles {
    let player: Session
    /// What Save As asks, and the one part of saving that needs somebody at the machine. Held as a
    /// function rather than written into `saveAs`, so that the rule about when Save has to ask at
    /// all can be exercised where there is nobody there to answer.
    let askWhereToSave: @MainActor (String) -> URL?

    public init(player: Session) {
      self.init(player: player, askWhereToSave: Self.savePanel)
    }

    init(player: Session, askWhereToSave: @escaping @MainActor (String) -> URL?) {
      self.player = player
      self.askWhereToSave = askWhereToSave
    }

    // MARK: Opening

    /// A song of one's own. Anything unsaved is asked about first, as this replaces it.
    func new() {
      guard confirmDiscard() else { return }
      player.new()
    }

    func openPanel() {
      guard confirmDiscard() else { return }
      let panel = NSOpenPanel()
      // `.json` too, for songs saved before `.driftbox` and for the web app's downloads.
      panel.allowedContentTypes = [.song, .json]
      panel.allowsMultipleSelection = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      load(url)
    }

    /// A file arriving from anywhere but the panel: a drop on the window, a double-click in the
    /// Finder, a drop on the dock icon, the recents menu.
    func open(_ url: URL) {
      guard confirmDiscard() else { return }
      load(url)
    }

    /// One of the songs that ship with the app.
    func open(_ entry: CatalogueEntry) {
      guard confirmDiscard() else { return }
      player.open(entry)
    }

    private func load(_ url: URL) {
      player.open(file: url)
      // Only a song that opened is worth offering again.
      if player.fileURL == url { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// What the Finder has handed the app lately, songs only: the recents list is the document
    /// controller's whether or not anything here is an `NSDocument`.
    var recent: [URL] {
      NSDocumentController.shared.recentDocumentURLs
    }

    func clearRecent() {
      NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: Saving

    /// Straight back to the file it came from, with no panel; a song that has never had one is a
    /// Save As in disguise. True when the song is safely on disk afterwards.
    @discardableResult
    func save() -> Bool {
      guard player.song != nil else { return true }
      guard let url = player.fileURL else { return saveAs() }
      player.save(to: url)
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
      return !player.isEdited
    }

    @discardableResult
    func saveAs() -> Bool {
      guard player.song != nil else { return true }
      guard let url = askWhereToSave(SongFile.fileName(for: player.documentName)) else { return false }
      player.save(to: url)
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
      return !player.isEdited
    }

    private static func savePanel(named name: String) -> URL? {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.song]
      panel.nameFieldStringValue = name
      guard panel.runModal() == .OK else { return nil }
      return panel.url
    }

    /// Ask before unsaved work is closed over. True when the caller may go ahead, which is at once
    /// when there is nothing to lose.
    func confirmDiscard() -> Bool {
      guard player.isEdited, player.song != nil else { return true }
      let alert = NSAlert()
      alert.messageText = "Do you want to save the changes you made to \(player.documentName)?"
      alert.informativeText = "Your changes will be lost if you don't save them."
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Don't Save")
      switch alert.runModal() {
      case .alertFirstButtonReturn: return save()
      case .alertThirdButtonReturn: return true
      default: return false
      }
    }

    // MARK: Exporting

    /// The whole song, offline, to a WAV file: the same render `driftbox-render` makes.
    func exportMix() {
      guard let song = player.song else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.wav]
      panel.nameFieldStringValue = player.documentName + ".wav"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      let sampleRate = player.sampleRate
      Task.detached {
        let audio = SongRenderer.render(song, options: .init(sampleRate: sampleRate))
        try? WAV.data(audio, sampleRate: sampleRate).write(to: url)
      }
    }

    /// The song and its visuals, as a movie: asked where, then written by the stage while the app
    /// carries on.
    func exportMovie(through stage: Stage) {
      guard player.song != nil else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.quickTimeMovie]
      panel.nameFieldStringValue = player.documentName + ".mov"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      stage.exportMovie(to: url)
    }

    /// One WAV per voice the song uses, into a folder: each voice alone with its sends.
    func exportStems() {
      guard let song = player.song else { return }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Export Here"
      guard panel.runModal() == .OK, let folder = panel.url else { return }
      let sampleRate = player.sampleRate
      let name = player.documentName
      Task.detached {
        for voiceId in SongRenderer.voicesUsed(song) {
          var options = SongRenderer.Options(sampleRate: sampleRate)
          options.only = [voiceId]
          let audio = SongRenderer.render(song, options: options)
          let file = folder.appendingPathComponent("\(name) - \(voiceId).wav")
          try? WAV.data(audio, sampleRate: sampleRate).write(to: file)
        }
      }
    }
  }

  /// The window's document identity, which SwiftUI has no words for: the file the song came from
  /// and its proxy icon, the dot in the close button while there are unsaved changes, and the
  /// question before that work is closed over. Sits in the background of the content, where it can
  /// reach the window without anything being drawn for it.
  struct WindowIdentity: NSViewRepresentable {
    let player: Session
    let files: SongFiles

    func makeNSView(context: Context) -> NSView {
      let view = NSView(frame: .zero)
      context.coordinator.view = view
      return view
    }

    func updateNSView(_ view: NSView, context: Context) {
      let coordinator = context.coordinator
      coordinator.files = files
      let file = player.fileURL
      let edited = player.isEdited
      // A view being made has no window yet, so the first pass waits a turn for one to arrive.
      Task { @MainActor in coordinator.apply(file: file, edited: edited) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
      weak var view: NSView?
      var files: SongFiles?
      private let close = CloseGuard()

      func apply(file: URL?, edited: Bool) {
        guard let window = view?.window else { return }
        if window.delegate !== close {
          close.next = window.delegate
          close.shouldClose = { [weak self] in self?.files?.confirmDiscard() ?? true }
          window.delegate = close
          // There is one player behind the window, so a second tab would be the same song twice,
          // each half of it claiming to be the document.
          window.tabbingMode = .disallowed
        }
        if window.representedURL != file { window.representedURL = file }
        if window.isDocumentEdited != edited { window.isDocumentEdited = edited }
      }
    }
  }

  /// Stands in front of the window's own delegate so that closing can be refused, and hands on
  /// everything else: SwiftUI's delegate is doing the rest of the window's work and would miss it.
  final class CloseGuard: NSObject, NSWindowDelegate {
    var shouldClose: @MainActor () -> Bool = { true }
    weak var next: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      guard shouldClose() else { return false }
      return next?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
      if super.responds(to: selector) { return true }
      return next?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { next }
  }

  /// What only an application object hears: songs opened from the Finder or dropped on the dock,
  /// and a quit that would take unsaved work with it.
  @MainActor
  public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var files: SongFiles?
    /// Opening a song in the Finder starts the app, so the first file can arrive before there is
    /// anything to open it into. It waits here for the window.
    private var waiting: [URL] = []

    /// Given somewhere to open files, it opens any that arrived first — and says so, because a
    /// song opened from the Finder is the one wanted, not whichever was open last time.
    @discardableResult
    public func attach(_ files: SongFiles) -> Bool {
      guard self.files == nil else { return false }
      self.files = files
      let queued = waiting
      waiting = []
      for url in queued { files.open(url) }
      return !queued.isEmpty
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
      guard let files else {
        waiting.append(contentsOf: urls)
        return
      }
      // One window, one song: the last one asked for is the one that gets opened.
      if let url = urls.last { files.open(url) }
    }

    /// One window holding one song, so closing it is what quitting means.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      (files?.confirmDiscard() ?? true) ? .terminateNow : .terminateCancel
    }
  }
#endif
