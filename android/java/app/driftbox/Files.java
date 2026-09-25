package app.driftbox;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * The song's file, through Android's own pickers: what Swift asks for as a frame's text (see
 * FileLines.swift), done here, where the storage access framework is, and the answer handed back.
 * A document is read and written whole, as text; Swift never sees more of it than that and its URI.
 */
final class Files {
  static final int OPEN = 7101;
  static final int CREATE = 7102;

  /** A song waiting for the create picker to say where it goes. */
  private static String waiting;

  private Files() {}

  /** Whether `message` is one of these rather than a menu; and if it is, done. */
  static boolean handle(Activity activity, String message) {
    int end = message.indexOf('\n');
    String head = end < 0 ? message : message.substring(0, end);
    String body = end < 0 ? "" : message.substring(end + 1);
    String[] fields = head.split("\t", -1);
    switch (fields[0]) {
      case "file":
        switch (fields[1]) {
          case "open":
            activity.startActivityForResult(
                new Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    // A song has no type Android knows: any document, and Swift says if it is one.
                    .setType("*/*"),
                OPEN);
            return true;
          case "create":
            waiting = body;
            activity.startActivityForResult(
                new Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    // Not JSON's type, which a provider would give its own ending to.
                    .setType("application/octet-stream")
                    .putExtra(Intent.EXTRA_TITLE, fields[2]),
                CREATE);
            return true;
          case "write":
            Uri uri = Uri.parse(fields[2]);
            Native.fileSaved(uri.toString(), name(activity, uri), write(activity, uri, body));
            return true;
          default:
            return true;
        }
      case "ask":
        new AlertDialog.Builder(activity)
            .setMessage(fields[1])
            .setPositiveButton("Lose them", (dialog, which) -> Native.menuChosen("confirmed"))
            .setNegativeButton("Keep them", null)
            .show();
        return true;
      default:
        return false;
    }
  }

  /** What a picker chose, if it is one of these. */
  static boolean result(Activity activity, int request, int code, Intent data) {
    if (request != OPEN && request != CREATE) return false;
    Uri uri = code == Activity.RESULT_OK && data != null ? data.getData() : null;
    if (uri == null) {
      waiting = null;
      return true;
    }
    // Kept across launches, so a song opened today saves back to where it came from tomorrow.
    try {
      activity
          .getContentResolver()
          .takePersistableUriPermission(
              uri, Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
    } catch (SecurityException e) {
      Log.i("Driftbox", "not kept: " + e.getMessage());
    }
    if (request == OPEN) {
      String text = read(activity, uri);
      if (text != null) Native.fileOpened(uri.toString(), name(activity, uri), text);
    } else {
      String song = waiting;
      waiting = null;
      if (song != null) Native.fileSaved(uri.toString(), name(activity, uri), write(activity, uri, song));
    }
    return true;
  }

  private static String read(Activity activity, Uri uri) {
    try (InputStream in = activity.getContentResolver().openInputStream(uri)) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buffer = new byte[65536];
      for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
      return out.toString(StandardCharsets.UTF_8.name());
    } catch (IOException | NullPointerException e) {
      Log.i("Driftbox", "could not read " + uri + ": " + e.getMessage());
      return null;
    }
  }

  /** Written whole, over whatever was there: "wt" truncates, where "w" alone may not. */
  private static boolean write(Activity activity, Uri uri, String text) {
    try (OutputStream out = activity.getContentResolver().openOutputStream(uri, "wt")) {
      out.write(text.getBytes(StandardCharsets.UTF_8));
      return true;
    } catch (IOException | NullPointerException | SecurityException e) {
      Log.i("Driftbox", "could not write " + uri + ": " + e.getMessage());
      return false;
    }
  }

  /** The document's name as its provider shows it, ending and all; its URI's last part if none. */
  private static String name(Activity activity, Uri uri) {
    try (Cursor cursor =
        activity
            .getContentResolver()
            .query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
      if (cursor != null && cursor.moveToFirst()) return cursor.getString(0);
    } catch (RuntimeException e) {
      Log.i("Driftbox", "no name for " + uri + ": " + e.getMessage());
    }
    String last = uri.getLastPathSegment();
    return last == null ? "Song" : last;
  }
}
