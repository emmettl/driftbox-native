/// Where the engine meets the machine: the AUAudioUnit, the lock-free rings between the interface
/// and the render thread, MIDI, and — later — hosted plug-ins. Nothing below this target knows
/// that an operating system exists.
public enum DriftboxHost {}
