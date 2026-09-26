/// A device sound can go out of, as every platform can describe one.
public struct AudioDevice: Hashable, Sendable {
  /// What it is called for good, which is what a choice of it is remembered by: CoreAudio's UID,
  /// or the endpoint ID Windows gives it. Not a number that changes when it is plugged back in.
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum AudioDevices {
  /// Which device to play through: the one chosen, while it is there to be played through,
  /// and the system's otherwise. A chosen interface that has been unplugged is not a reason
  /// to make no sound, and it is not forgotten either — when it comes back, so does the sound.
  public static func pick(chosen: String?, among devices: [AudioDevice], systemDefault: AudioDevice?)
    -> AudioDevice?
  {
    if let chosen, let found = devices.first(where: { $0.id == chosen }) { return found }
    return systemDefault
  }
}

/// Where the sound goes, and what makes it: a platform's audio output, kept on the device it
/// should be on as devices come and go.
///
/// This is the whole of what the rest of Driftbox asks of a platform's audio. It says nothing
/// about how a platform does it — an `AVAudioEngine` on the Mac, a WASAPI stream on Windows — and
/// nothing that is not platform-neutral crosses it: devices by name and ID, sources as a
/// `RenderSource`, and a latency in seconds.
@MainActor
public protocol AudioRouting: AnyObject {
  /// The device chosen, by its ID; nil for whatever the system is playing through.
  var chosen: String? { get set }
  /// Every device there is, as of the last change to any of them.
  var devices: [AudioDevice] { get }
  /// The device the sound is going out of.
  var current: AudioDevice? { get }
  /// The device the system is playing through, which is where the sound goes when nothing else
  /// has been chosen, or what has been is not there.
  var systemDefault: AudioDevice? { get }
  /// Why there is no sound, if there is none.
  var error: String? { get }
  /// Called after anything above changes, on the main actor.
  var onChange: (() -> Void)? { get set }
  /// The rate sources are rendered at. The device may run at another; the output converts.
  var sampleRate: Double { get }
  /// How long after a frame is rendered it is heard, in seconds: what a MIDI clock sent out
  /// alongside the music has to allow for.
  var latency: Double { get }

  /// Play `source` from now on, mixed with whatever else is playing.
  func attach(_ source: RenderSource)
  /// Stop playing the source whose context is `context`. It is not called again once this returns.
  func detach(_ context: UnsafeMutableRawPointer)
}

/// Where live sound comes in from — a microphone, an interface's inputs — for the rack's Audio
/// Input module: a platform's audio input, kept on the device it should be on as devices come and
/// go, as `AudioRouting` keeps the output.
///
/// It captures only while it has somewhere to put what it hears. Until then no device is open,
/// so a system that shows when something is listening does not say so for a patch that is not.
@MainActor
public protocol AudioCapturing: AnyObject {
  /// The device chosen, by its ID; nil for whatever the system is listening to.
  var chosen: String? { get set }
  /// Every device there is to listen to, as of the last change to any of them.
  var devices: [AudioDevice] { get }
  /// The device being heard, while one is.
  var current: AudioDevice? { get }
  /// The device the system listens to, which is what is heard when nothing else has been chosen,
  /// or what has been is not there.
  var systemDefault: AudioDevice? { get }
  /// Why nothing can be heard, while something should be and nothing can.
  var error: String? { get }
  /// Called after anything above changes, on the main actor.
  var onChange: (() -> Void)? { get set }
  /// Where what comes in goes, from now on; nil to hear nothing, and let go of the device.
  var destination: LiveInput? { get set }
}
