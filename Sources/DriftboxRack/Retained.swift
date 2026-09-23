// A rack document that carries a groovebox song: the reference's `groovebox.ts` in
// `driftbox/packages/rack/src`. The song is embedded whole, as its document's text, and played
// beside the rack by the host; the rack's own `groovebox` module is how its machines come in.

/// What saving a document keeps, which is what the rack says about one it did not author: the
/// reference's `PatchCompatibility`.
public enum PatchCompatibility: Sendable, Equatable {
  /// No song in it: a rack patch like any other.
  case rackNative
  /// A song and nothing the rack added but its derived source, untouched: the song, whole, and
  /// nothing lost by taking it back to the groovebox.
  case grooveboxCompatible
  /// A song and rack work besides it: modules, cables, a tempo of its own, anything.
  case rackExtended
}

extension Patch {
  /// The reference's `patchCompatibility`: every rack-authored field counts, so that nothing
  /// implies the song alone is the whole document when the rack has added to it.
  public var compatibility: PatchCompatibility {
    guard groovebox != nil else { return .rackNative }
    let sources = modules.filter { $0.type == "groovebox" }
    let derivedSourceOnly = sources.count <= 1 && sources.allSatisfy { $0.params.isEmpty && $0.data.isEmpty }
    let rackState =
      modules.contains { $0.type != "groovebox" } || !derivedSourceOnly || !cables.isEmpty || visual != nil
      || breakId != nil || !modulation.isEmpty || (voices ?? 1) > 1 || tempo != nil
    return rackState ? .rackExtended : .grooveboxCompatible
  }

  /// A patch made of a song: the song's document, and the groovebox source its machines come in by,
  /// under the first `groovebox` id free — the reference's `embedGrooveboxSong`, which puts the
  /// source first.
  public static func embedding(song text: String) -> Patch {
    var patch = Patch(modules: [PatchModule(id: "groovebox", type: "groovebox")], cables: [])
    patch.groovebox = text
    return patch
  }
}
