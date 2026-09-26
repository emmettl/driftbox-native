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

  /** The typesetter, held to what every platform's is, on a thread of Swift's own. */
  static native String textCheck();

  /** Every scene drawn, checked, and timed on a screen width by height at density. Blocks. */
  static native String sceneCheck(int width, int height, float density);

  /**
   * Every patch in the rack's catalogue, unpacked into {@code resources}, opened and run for a
   * second. On the main thread, which the rack session is on; blocks while it renders.
   */
  static native String rackCheck(String resources);

  /**
   * Play the catalogue's song {@code song}, and draw a scene from it, with the controls over it, in
   * whatever window it is given: the scene called {@code scene}, or the one the song names when that
   * is null. {@code resources} is the directory {@link Main} unpacked the catalogue and its songs into.
   */
  static native boolean start(String song, String scene, float density, String resources);

  /**
   * A frame, drawn now: the {@code Choreographer}'s, once for each refresh of the display. Returns
   * the menu a long press has asked for since the last, as {@link Menus} reads it, or null.
   */
  static native String frame();

  /** The command with this id chosen from the menu the last frame returned. */
  static native void menuChosen(String id);

  /** A song document the open picker chose, read whole: its URI, its name, and its text. */
  static native void fileOpened(String uri, String name, String text);

  /** Recordings chosen for the rack's `module`, copied into the app's files: their paths, a line each. */
  static native void samplesChosen(String module, String paths);

  /** The song written to the document at `uri`, called `name`; or not. */
  static native void fileSaved(String uri, String name, boolean done);

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

  /**
   * A finger, {@code id} as Android numbers it, at x, y in points from the top left: {@code phase}
   * 0 down, 1 moved, 2 lifted, 3 taken away.
   */
  static native void touch(int id, int phase, float x, float y);

  /** The devices sound can go out of, as {@link Outputs} describes them, on the main thread. */
  static native void outputs(String lines);

  /** Once a second, on the main thread: housekeeping, and a line for the log. */
  static native String tick();
}
