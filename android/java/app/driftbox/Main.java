package app.driftbox;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
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
 * the screen a pad for the performance filter. Two fingers tapped step on to the next scene. Out of
 * view, or with the screen off, the song plays on, through {@link Playback}; it pauses for a call
 * or another app's playing, as media does. Which song and which scene are extras, a catalogue id
 * and a scene's:
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
  private AudioFocusRequest focus;
  /** The one there is while a song plays, for the notification's Stop to reach. Main thread only. */
  private static Main current;

  /** The notification's Stop: the song and everything playing it ended, and the app with them. */
  static void stopPlaying() {
    if (current != null) {
      current.finish();
    } else {
      Native.stop();
    }
  }

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

  // Out of sight, nothing is drawn; the song plays on, the Playback service keeping the process on
  // the big cores for it.
  @Override
  protected void onStop() {
    if (playing) Native.setDrawing(false);
    super.onStop();
  }

  @Override
  protected void onStart() {
    super.onStart();
    if (playing) Native.setDrawing(true);
  }

  @Override
  protected void onDestroy() {
    handler.removeCallbacksAndMessages(null);
    if (playing) {
      getSystemService(AudioManager.class).abandonAudioFocusRequest(focus);
      stopService(new Intent(this, Playback.class));
      Native.stop();
      current = null;
    }
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
    current = this;
    Log.i(TAG, "playing " + song);
    // Started now, while the app is in view, which is the only time Android allows it.
    startForegroundService(new Intent(this, Playback.class).putExtra("song", song));
    if (Build.VERSION.SDK_INT >= 33
        && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
      // Without it the song still plays; Android only keeps its notification out of sight.
      requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 0);
    }
    // Paused for a call or for another app's playing, and played again after the first.
    focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build())
        .setOnAudioFocusChangeListener(change -> {
          if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            Native.setPlaying(false);
          } else if (change == AudioManager.AUDIOFOCUS_GAIN) {
            Native.setPlaying(true);
          }
        }, handler)
        .build();
    getSystemService(AudioManager.class).requestAudioFocus(focus);
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
        Log.i(TAG, Native.tick() + ", in the " + cpuset() + " cpuset");
        handler.postDelayed(this, 1000);
      }
    }, 1000);
  }

  /** Which of Android's cpusets the process is in, which says which cores it may run on. */
  private static String cpuset() {
    try (InputStream in = new java.io.FileInputStream("/proc/self/cpuset")) {
      byte[] bytes = new byte[64];
      int read = in.read(bytes);
      return read > 0 ? new String(bytes, 0, read, StandardCharsets.UTF_8).trim() : "unknown";
    } catch (IOException e) {
      return "unknown";
    }
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
