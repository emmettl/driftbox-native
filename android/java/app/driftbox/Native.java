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

  /** The GPU contract's checks, on this phone's GPU, through OpenGL ES. Blocks while it draws. */
  static native String gpuCheck();

  /** Every scene drawn, checked, and timed on a screen width by height at density. Blocks. */
  static native String sceneCheck(int width, int height, float density);

  /**
   * Play a song document, and draw a scene from it in whatever window it is given: the one called
   * {@code scene}, or the one the song names when that is null.
   */
  static native boolean start(String json, String scene, float density);

  /** Show the next scene there is. */
  static native void nextScene();

  /** Stop playing and drawing, and wait until both have. */
  static native void stop();

  /** Draw, or draw nothing: the app in view, or out of it. */
  static native void setDrawing(boolean drawing);

  /** Play, or pause where the song is and let go of the audio stream until playing again. */
  static native void setPlaying(boolean playing);

  /** Draw in this window, of this size, from now on. */
  static native void surfaceChanged(android.view.Surface surface, int width, int height);

  /** Stop drawing in the window, having let go of it by the time this returns. */
  static native void surfaceDestroyed();

  /** A finger at x, y, 0...1 from the bottom left, down or lifted. */
  static native void touch(float x, float y, boolean down);

  /** Once a second, on the main thread: housekeeping, and a line for the log. */
  static native String tick();
}
