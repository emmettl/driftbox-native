#if os(Android)
  /// What the song's menu asks of Java that is not a menu — a picker to open a song or save one,
  /// a document written, a question — as the text a frame returns, as a menu is (`MenuLines`). The
  /// first line says what, a tab between its fields; a song goes after it, whole.
  ///
  ///     file  open                    choose a song document, and read it: `Native.fileOpened`
  ///     file  create  name            choose where to save the song below as `name`, and write it:
  ///     <the song's document>         `Native.fileSaved`
  ///     file  write  location         write the song below over the document at `location`
  ///     <the song's document>
  ///     ask  question                 ask, and choose `confirmed` for yes: `Native.menuChosen`
  ///
  /// A menu's first line begins with a number, so neither can be taken for the other.
  enum FileLines {
    static let open = "file\topen"

    static func create(_ document: String, named name: String) -> String {
      "file\tcreate\t\(clean(name))\n\(document)"
    }

    static func write(_ document: String, to location: String) -> String {
      "file\twrite\t\(clean(location))\n\(document)"
    }

    static func ask(_ question: String) -> String { "ask\t\(clean(question))" }

    /// What Java chooses when a question is answered yes.
    static let confirmed = "confirmed"

    private static func clean(_ text: String) -> String {
      String(text.map { $0 == "\t" || $0 == "\n" ? " " : $0 })
    }
  }
#endif
