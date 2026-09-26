#if os(Linux)
  import Foundation
  import Testing

  @testable import DriftboxGTK

  @MainActor struct FileURITests {
    @Test func escapedNamesRemainOneFileEachAndKeepTheirOrder() {
      let files = GTKWindow.localFiles(
        "file:///tmp/one%20two.wav\nfile:///tmp/line%0Abreak.driftbox\nfile:///tmp/%C3%A9.wav\n")
      #expect(files.map(\.path) == ["/tmp/one two.wav", "/tmp/line\nbreak.driftbox", "/tmp/é.wav"])
    }

    @Test func remoteAndRelativeLocationsAreNotLocalImports() {
      let files = GTKWindow.localFiles(
        "https://example.com/song.driftbox\nfile://server/share.wav\nsong.driftbox\nfile:///tmp/local.wav\nfile://localhost/tmp/also.wav"
      )
      #expect(files.map(\.path) == ["/tmp/local.wav", "/tmp/also.wav"])
      #expect(GTKWindow.localFiles("").isEmpty)
    }
  }
#endif
