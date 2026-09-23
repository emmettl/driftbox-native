package app.driftbox;

import android.media.midi.MidiDevice;

/** Swift, in libdriftbox.so: `Sources/DriftboxAndroid`. */
final class Native {
  static {
    System.loadLibrary("driftbox");
  }

  private Native() {}

  /** An open device, handed to Swift, which owns its native side from here. */
  static native void deviceAdded(int id, String name, MidiDevice device);

  /** A device gone. Swift closes its ports and releases it; Java closes it after. */
  static native void deviceRemoved(int id);

  /** Sends through Driftbox Loopback and says what came back. Blocks for about a second. */
  static native String midiLoopback();
}
