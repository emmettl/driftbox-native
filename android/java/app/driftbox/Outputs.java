package app.driftbox;

import android.content.Context;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;

/**
 * The phone's audio outputs, for Swift to play through: AAudio plays a device by number but cannot
 * list them, which is {@code AudioManager}'s. Listed whole each time one comes or goes, a line each
 * — the number, a name for good, and what it is called — since Android's number changes when a
 * device is plugged back in and a choice of it should not be forgotten.
 */
final class Outputs extends AudioDeviceCallback {
  private final AudioManager manager;

  Outputs(Context context) {
    manager = context.getSystemService(AudioManager.class);
  }

  /** Listing from now on, on the main thread; Android lists what there is at once. */
  void start() {
    manager.registerAudioDeviceCallback(this, null);
  }

  void stop() {
    manager.unregisterAudioDeviceCallback(this);
  }

  @Override
  public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
    list();
  }

  @Override
  public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
    list();
  }

  private void list() {
    StringBuilder lines = new StringBuilder();
    for (AudioDeviceInfo device : manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
      String kind = kind(device.getType());
      if (kind == null) continue;
      CharSequence product = device.getProductName();
      String named = product == null ? "" : clean(product.toString());
      String key = kind + ":" + named + ":" + clean(device.getAddress());
      lines.append(device.getId()).append('\t').append(key).append('\t').append(name(kind, named)).append('\n');
    }
    Native.audioOutputs(lines.toString());
  }

  /**
   * What an output is, for its name for good, or null for one that is not somewhere to send music:
   * the earpiece, a call's Bluetooth, and Android's own plumbing.
   */
  private static String kind(int type) {
    switch (type) {
      case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
        return "speaker";
      case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
      case AudioDeviceInfo.TYPE_WIRED_HEADSET:
        return "wired";
      case AudioDeviceInfo.TYPE_USB_DEVICE:
      case AudioDeviceInfo.TYPE_USB_HEADSET:
      case AudioDeviceInfo.TYPE_USB_ACCESSORY:
        return "usb";
      case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
      case AudioDeviceInfo.TYPE_BLE_HEADSET:
      case AudioDeviceInfo.TYPE_BLE_SPEAKER:
        return "bluetooth";
      case AudioDeviceInfo.TYPE_HDMI:
      case AudioDeviceInfo.TYPE_HDMI_ARC:
      case AudioDeviceInfo.TYPE_HDMI_EARC:
        return "hdmi";
      case AudioDeviceInfo.TYPE_LINE_ANALOG:
      case AudioDeviceInfo.TYPE_LINE_DIGITAL:
        return "line";
      case AudioDeviceInfo.TYPE_DOCK:
        return "dock";
      case AudioDeviceInfo.TYPE_HEARING_AID:
        return "hearing";
      default:
        return null;
    }
  }

  /** What it is called in the menu: the phone's own parts by what they are, the rest by product. */
  private static String name(String kind, String product) {
    switch (kind) {
      case "speaker":
        return "Speaker";
      case "wired":
        return "Headphones";
      case "line":
        return "Line Out";
      case "hdmi":
        return product.isEmpty() ? "HDMI" : "HDMI: " + product;
      default:
        if (!product.isEmpty()) return product;
        return kind.equals("usb") ? "USB Audio" : kind.equals("bluetooth") ? "Bluetooth" : "Output";
    }
  }

  /** Free of the tabs and newlines the lines are split by. */
  private static String clean(String text) {
    return text == null ? "" : text.replace('\t', ' ').replace('\n', ' ');
  }
}
