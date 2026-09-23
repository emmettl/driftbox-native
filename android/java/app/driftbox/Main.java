package app.driftbox;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

/**
 * The app, so far a harness. Started with a test's name, it runs it and says what happened, on
 * screen and in the log under "Driftbox":
 *
 * <pre>adb shell am start -n app.driftbox/.Main --es run midi-loopback</pre>
 */
public final class Main extends Activity {
  static final String TAG = "Driftbox";
  private Midi midi;

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    TextView text = new TextView(this);
    text.setPadding(48, 48, 48, 48);
    text.setText("Driftbox");
    setContentView(text);
    midi = new Midi(this);
    String run = getIntent().getStringExtra("run");
    if ("midi-loopback".equals(run)) {
      new Thread(() -> {
        String report;
        try {
          report = midi.await("Driftbox Loopback", 5000)
              ? Native.midiLoopback()
              : "FAIL Driftbox Loopback never arrived";
        } catch (InterruptedException e) {
          report = "FAIL interrupted";
        }
        for (String line : report.split("\n")) Log.i(TAG, line);
        Log.i(TAG, "done");
        String shown = report;
        runOnUiThread(() -> text.setText(shown));
      }, "Driftbox test").start();
    }
  }
}
