package app.driftbox;

import android.media.AudioDeviceInfo;
import java.util.HashSet;
import java.util.Set;

/**
 * The devices sound can go out of, as Swift's route reads them: a line each, an ID that is the
 * same each time the device is plugged in, the number AAudio opens it by, which is not, and a name
 * to show, apart by tabs. Only what music is played through: not the earpiece, a call's Bluetooth,
 * or what the system routes inside itself.
 */
final class Outputs {
  private Outputs() {}

  static String describe(AudioDeviceInfo[] devices) {
    StringBuilder lines = new StringBuilder();
    Set<String> seen = new HashSet<>();
    for (AudioDeviceInfo device : devices) {
      if (!device.isSink()) continue;
      String kind = kind(device.getType());
      if (kind == null) continue;
      String product = device.getProductName() == null ? "" : device.getProductName().toString().trim();
      String address = device.getAddress() == null ? "" : device.getAddress();
      String id = kind + ":" + (address.isEmpty() ? product : address);
      // One device can be listed more than once, for its several ways in; the first is played.
      if (!seen.add(id)) continue;
      lines.append(id.replace('\t', ' ').replace('\n', ' ')).append('\t')
          .append(device.getId()).append('\t')
          .append(name(kind, product).replace('\t', ' ').replace('\n', ' ')).append('\n');
    }
    return lines.toString();
  }

  /** What kind of output it is, or null for one music is not played through. */
  private static String kind(int type) {
    switch (type) {
      case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
        return "speaker";
      case AudioDeviceInfo.TYPE_WIRED_HEADSET:
      case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
        return "wired";
      case AudioDeviceInfo.TYPE_LINE_ANALOG:
      case AudioDeviceInfo.TYPE_LINE_DIGITAL:
        return "line";
      case AudioDeviceInfo.TYPE_USB_DEVICE:
      case AudioDeviceInfo.TYPE_USB_ACCESSORY:
      case AudioDeviceInfo.TYPE_USB_HEADSET:
        return "usb";
      case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
        return "bluetooth";
      case AudioDeviceInfo.TYPE_BLE_HEADSET:
      case AudioDeviceInfo.TYPE_BLE_SPEAKER:
        return "ble";
      case AudioDeviceInfo.TYPE_HDMI:
      case AudioDeviceInfo.TYPE_HDMI_ARC:
      case AudioDeviceInfo.TYPE_HDMI_EARC:
        return "hdmi";
      case AudioDeviceInfo.TYPE_HEARING_AID:
        return "hearing-aid";
      // A dock's speakers or line out, digital or, from Android 14, analogue: a constant, so
      // naming the newer one on an older Android costs nothing but never matching.
      case AudioDeviceInfo.TYPE_DOCK:
      case AudioDeviceInfo.TYPE_DOCK_ANALOG:
        return "dock";
      default:
        return null;
    }
  }

  private static String name(String kind, String product) {
    switch (kind) {
      case "speaker":
        return "Speaker";
      case "wired":
        return "Headphones";
      case "line":
        return "Line Out";
      case "hdmi":
        return "HDMI";
      case "hearing-aid":
        return product.isEmpty() ? "Hearing Aid" : product;
      case "dock":
        return product.isEmpty() ? "Dock" : product;
      default:
        // USB and Bluetooth by their own names, which say which of them it is.
        return product.isEmpty() ? (kind.equals("usb") ? "USB Audio" : "Bluetooth") : product;
    }
  }
}
