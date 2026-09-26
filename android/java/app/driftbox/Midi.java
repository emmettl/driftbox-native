package app.driftbox;

import android.content.Context;
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/**
 * Every MIDI device Android has, opened and handed to Swift as it comes, and taken back as it
 * goes. Android's native MIDI plays through a device but cannot find or open one; this is the
 * part that can, and all of it. Everything after the handing over is Swift's. A phone without
 * MIDI has no manager to ask, and so no devices; the app plays on without them.
 */
final class Midi {
  /** Null on a phone without MIDI. */
  private final MidiManager manager;
  private final Handler handler = new Handler(Looper.getMainLooper());
  /** Open devices by Java's ID, kept open for as long as Swift has them. Main thread only. */
  private final Map<Integer, MidiDevice> open = new HashMap<>();
  /** Names handed over so far, for whoever is waiting for one. */
  private final Map<String, Boolean> named = new HashMap<>();

  // getDevices() is deprecated from Android 13 for a per-transport list, but it is the one that
  // reaches back to Android 10, and every device here is a byte stream either way.
  @SuppressWarnings("deprecation")
  Midi(Context context) {
    manager = context.getSystemService(MidiManager.class);
    if (manager == null) return;
    manager.registerDeviceCallback(
        new MidiManager.DeviceCallback() {
          @Override
          public void onDeviceAdded(MidiDeviceInfo info) {
            open(info);
          }

          @Override
          public void onDeviceRemoved(MidiDeviceInfo info) {
            close(info.getId());
          }
        },
        handler);
    for (MidiDeviceInfo info : manager.getDevices()) open(info);
  }

  private void open(MidiDeviceInfo info) {
    if (open.containsKey(info.getId())) return;
    manager.openDevice(
        info,
        device -> {
          if (device == null || open.containsKey(info.getId())) return;
          open.put(info.getId(), device);
          String name = nameOf(info);
          Native.deviceAdded(info.getId(), name, device);
          synchronized (named) {
            named.put(name, true);
            named.notifyAll();
          }
        },
        handler);
  }

  private void close(int id) {
    MidiDevice device = open.remove(id);
    if (device == null) return;
    Native.deviceRemoved(id);
    try {
      device.close();
    } catch (IOException ignored) {
    }
  }

  /** What people call it: its name, or its maker and product. */
  static String nameOf(MidiDeviceInfo info) {
    Bundle properties = info.getProperties();
    String name = properties.getString(MidiDeviceInfo.PROPERTY_NAME);
    if (name != null && !name.isEmpty()) return name;
    String maker = properties.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER, "");
    String product = properties.getString(MidiDeviceInfo.PROPERTY_PRODUCT, "MIDI");
    return (maker + " " + product).trim();
  }

  /** Waits up to `milliseconds` for a device called `name` to have been handed over. */
  boolean await(String name, long milliseconds) throws InterruptedException {
    long until = System.currentTimeMillis() + milliseconds;
    synchronized (named) {
      while (!named.containsKey(name)) {
        long left = until - System.currentTimeMillis();
        if (left <= 0) return false;
        named.wait(left);
      }
    }
    return true;
  }
}
