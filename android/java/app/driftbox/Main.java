package app.driftbox;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * The app, so far: a song played, with the scene it names drawn from it over the whole screen, and
 * the screen a pad for the performance filter. Two fingers tapped step on to the next scene. Which
 * song and which scene are extras, a catalogue id and a scene's:
 *
 * <pre>adb shell am start -n app.driftbox/.Main --es song smallhours --es scene hothouse</pre>
 *
 * Or a harness, started with a test's name, which runs it and says what happened, on screen and in
 * the log under "Driftbox": {@code --es run midi-loopback}, {@code gpu} for the GPU contract on this
 * phone's GPU, or {@code scenes} for every scene drawn, checked and timed.
 */
public final class Main extends Activity {
  static final String TAG = "Driftbox";
  private Midi midi;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private boolean playing;

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    midi = new Midi(this);
    String run = getIntent().getStringExtra("run");
    if ("midi-loopback".equals(run) || "gpu".equals(run) || "scenes".equals(run)) {
      test(run);
    } else {
      String song = getIntent().getStringExtra("song");
      play(song == null ? "acid" : song, getIntent().getStringExtra("scene"));
    }
  }

  // Out of sight, the app leaves Android's top-app cpuset for one with only the little cores, where
  // the audio's render thread cannot keep up: so the song stops where it is, the audio stream is let
  // go of and nothing is drawn, and all of it starts again on the way back. Playing on unseen wants
  // a media playback service, which keeps the big cores.
  @Override
  protected void onStop() {
    if (playing) Native.setShown(false);
    super.onStop();
  }

  @Override
  protected void onStart() {
    super.onStart();
    if (playing) Native.setShown(true);
  }

  @Override
  protected void onDestroy() {
    handler.removeCallbacksAndMessages(null);
    if (playing) Native.stop();
    super.onDestroy();
  }

  // MARK: - Pulse

  private void play(String song, String scene) {
    String json;
    try {
      json = asset("songs/" + song + ".song.json");
    } catch (IOException e) {
      Log.e(TAG, "no song called " + song + ": " + e);
      finish();
      return;
    }
    if (!Native.start(json, scene, getResources().getDisplayMetrics().density)) {
      Log.e(TAG, song + " is not a song");
      finish();
      return;
    }
    playing = true;
    Log.i(TAG, "playing " + song);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    SurfaceView view = new SurfaceView(this);
    view.getHolder().addCallback(
        new SurfaceHolder.Callback() {
          @Override
          public void surfaceCreated(SurfaceHolder holder) {}

          @Override
          public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
            Native.surfaceChanged(holder.getSurface(), width, height);
          }

          @Override
          public void surfaceDestroyed(SurfaceHolder holder) {
            // Returns once Swift has let go of the window, which Android wants before this does.
            Native.surfaceDestroyed();
          }
        });
    view.setOnTouchListener(
        (touched, event) -> {
          int action = event.getActionMasked();
          // A second finger down, while the first is: the next scene. The first stays the pad's.
          if (action == MotionEvent.ACTION_POINTER_DOWN && event.getPointerCount() == 2) {
            Native.nextScene();
            return true;
          }
          if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP) {
            return true;
          }
          boolean down = action != MotionEvent.ACTION_UP && action != MotionEvent.ACTION_CANCEL;
          // 0...1 from the bottom left, as the engine's pad and Pulse both take it.
          float x = Math.max(0, Math.min(1, event.getX() / touched.getWidth()));
          float y = Math.max(0, Math.min(1, 1 - event.getY() / touched.getHeight()));
          Native.touch(x, y, down);
          return true;
        });
    setContentView(view);
    if (Build.VERSION.SDK_INT >= 30) {
      getWindow().setDecorFitsSystemWindows(false);
      view.getWindowInsetsController().hide(WindowInsets.Type.systemBars());
    }
    handler.postDelayed(new Runnable() {
      @Override
      public void run() {
        Log.i(TAG, Native.tick());
        handler.postDelayed(this, 1000);
      }
    }, 1000);
  }

  private String asset(String path) throws IOException {
    try (InputStream in = getAssets().open(path)) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buffer = new byte[16384];
      for (int read; (read = in.read(buffer)) > 0; ) out.write(buffer, 0, read);
      return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }
  }

  // MARK: - Tests

  private void test(String run) {
    TextView text = new TextView(this);
    text.setPadding(48, 48, 48, 48);
    text.setText("Driftbox");
    setContentView(text);
    new Thread(() -> {
      String report;
      try {
        if ("gpu".equals(run)) {
          report = Native.gpuCheck();
        } else if ("scenes".equals(run)) {
          android.util.DisplayMetrics screen = new android.util.DisplayMetrics();
          getWindowManager().getDefaultDisplay().getRealMetrics(screen);
          report = Native.sceneCheck(screen.widthPixels, screen.heightPixels, screen.density);
        } else {
          report = midi.await("Driftbox Loopback", 5000)
              ? Native.midiLoopback()
              : "FAIL Driftbox Loopback never arrived";
        }
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
