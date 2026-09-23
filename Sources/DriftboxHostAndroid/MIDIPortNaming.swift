/// What a MIDI port on Android is called, as the rest of Driftbox knows it.
///
/// A port is chosen and ignored by name, on every platform, so a name has to say which port it
/// is and stay the same when the device comes back. Android names devices but not their ports, so
/// a device with one port in a direction is known by its own name, and one with more by its name
/// and a number from one. Two devices of the same name, two of the same controller, are told apart
/// by the order they arrived in.
///
/// Platform-neutral, so that it is tested wherever the package builds.
public enum MIDIPortNaming {
  /// `name`, or `name 2`, `name 3` and so on: the first of them not in `taken`.
  public static func unique(_ name: String, among taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    var number = 2
    while taken.contains("\(name) \(number)") { number += 1 }
    return "\(name) \(number)"
  }

  /// Port `number`, from zero, of the `count` a device called `device` has in one direction.
  public static func port(_ number: Int, of count: Int, on device: String) -> String {
    count == 1 ? device : "\(device) port \(number + 1)"
  }
}
