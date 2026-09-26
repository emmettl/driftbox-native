package app.driftbox;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Choreographer;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * The app, so far: a song played, with the scene it names drawn from it over the whole screen, the
 * controls over it, and the rest of the screen a pad for the performance filter. A second finger
 * tapped while one is on the pad steps on to the next scene. Out of
 * view, or with the screen off, the song plays on, through {@link Playback}; it pauses for a call
 * or another app's playing, as media does. Which song and which scene are extras, a catalogue id
 * and a scene's:
 *
 * <pre>adb shell am start -n app.driftbox/.Main --es song smallhours --es scene hothouse</pre>
 *
 * Or a harness, started with a test's name, which runs it and says what happened, on screen and in
 * the log under "Driftbox": {@code --es run midi-loopback}, {@code gpu} for the GPU contract on this
 * phone's GPU, {@code scenes} for every scene drawn, checked and timed, {@code text} for the
 * typesetter, or {@code rack} for every patch of the rack's opened and run. A release has none of
 * them, as {@link Checks} says.
 */
public final class Main extends Activity {
  static final String TAG = "Driftbox";
  private Midi midi;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private boolean playing;
  private AudioFocusRequest focus;
  /** The one there is while a song plays, for the notification's Stop to reach. Main thread only. */
  private static Main current;
  /** Where a long press's menu opens from, moved to the finger. */
  private View anchor;

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
    // A phone kept upright: on its side it is too short for the grid and the knobs, which a
    // tablet, turned either way, has room for. Narrower than 600dp is a phone, as the controls
    // take it.
    if (getResources().getConfiguration().smallestScreenWidthDp < 600) {
      setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
    }
    midi = new Midi(this);
    String run = getIntent().getStringExtra("run");
    if (Checks.INCLUDED && ("midi-loopback".equals(run) || "gpu".equals(run) || "scenes".equals(run)
        || "text".equals(run) || "rack".equals(run))) {
      test(run);
    } else {
      String song = getIntent().getStringExtra("song");
      // None named: the one open last, which Swift remembers, or acid.
      play(song, getIntent().getStringExtra("scene"));
    }
  }

  // Out of sight, nothing is drawn; the song plays on, the Playback service keeping the process on
  // the big cores for it.
  @Override
  protected void onStop() {
    if (playing) {
      Choreographer.getInstance().removeFrameCallback(frames);
      Native.setDrawing(false);
    }
    super.onStop();
  }

  @Override
  protected void onStart() {
    super.onStart();
    if (playing) {
      Native.setDrawing(true);
      Choreographer.getInstance().postFrameCallback(frames);
    }
  }

  /** A frame for every refresh of the display, drawn on this thread, while the app is in view. */
  private final Choreographer.FrameCallback frames =
      new Choreographer.FrameCallback() {
        @Override
        public void doFrame(long nanos) {
          String menu = Native.frame();
          if (menu != null && !Files.handle(Main.this, menu) && anchor != null) {
            Menus.show(anchor, menu, getResources().getDisplayMetrics().density);
          }
          Choreographer.getInstance().postFrameCallback(this);
        }
      };

  @Override
  protected void onActivityResult(int request, int code, Intent data) {
    if (!Files.result(this, request, code, data)) super.onActivityResult(request, code, data);
  }

  @Override
  protected void onDestroy() {
    handler.removeCallbacksAndMessages(null);
    if (playing) {
      getSystemService(AudioManager.class).abandonAudioFocusRequest(focus);
      getSystemService(AudioManager.class).unregisterAudioDeviceCallback(outputs);
      stopService(new Intent(this, Playback.class));
      Native.stop();
      current = null;
    }
    super.onDestroy();
  }

  /** Every device sound can go out of, to Swift, whenever one comes or goes. */
  private final AudioDeviceCallback outputs =
      new AudioDeviceCallback() {
        @Override
        public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
          sendOutputs();
        }

        @Override
        public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
          sendOutputs();
        }
      };

  private void sendOutputs() {
    AudioDeviceInfo[] all = getSystemService(AudioManager.class).getDevices(AudioManager.GET_DEVICES_OUTPUTS);
    Native.outputs(Outputs.describe(all));
  }

  // MARK: - Playing

  private void play(String song, String scene) {
    File resources;
    try {
      resources = unpack();
    } catch (IOException e) {
      Log.e(TAG, "could not unpack the catalogue: " + e);
      finish();
      return;
    }
    if (!Native.start(song, scene, getResources().getDisplayMetrics().density, resources.getPath())) {
      Log.e(TAG, song == null ? "no song to play" : "no song called " + song + " in the catalogue");
      finish();
      return;
    }
    playing = true;
    current = this;
    Log.i(TAG, song == null ? "playing the song open last" : "playing " + song);
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
    // The devices there are, to choose between, now and as they come and go: registering says
    // what is there at once.
    getSystemService(AudioManager.class).registerAudioDeviceCallback(outputs, handler);
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
    // Every finger, in points, to Swift, which decides what each is: the controls', the pad's, or
    // a gesture's.
    float density = getResources().getDisplayMetrics().density;
    view.setOnTouchListener(
        (touched, event) -> {
          int action = event.getActionMasked();
          switch (action) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP: {
              int index = event.getActionIndex();
              int phase = action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_POINTER_DOWN ? 0 : 2;
              Native.touch(event.getPointerId(index), phase, event.getX(index) / density,
                  event.getY(index) / density);
              break;
            }
            case MotionEvent.ACTION_MOVE:
            case MotionEvent.ACTION_CANCEL:
              for (int index = 0; index < event.getPointerCount(); index++) {
                Native.touch(event.getPointerId(index), action == MotionEvent.ACTION_MOVE ? 1 : 3,
                    event.getX(index) / density, event.getY(index) / density);
              }
              break;
            default:
              break;
          }
          return true;
        });
    // The scene and the controls, and over them a point-sized view that a long press's menu opens from.
    FrameLayout root = new FrameLayout(this);
    root.addView(view);
    anchor = new View(this);
    root.addView(anchor, new FrameLayout.LayoutParams(1, 1));
    setContentView(root);
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

  /**
   * The session's resources — the catalogue and its songs, and the rack's patches — copied out of
   * the package into a directory of the app's own, since Swift reads them as files, and where.
   * Copied every time the app starts: they are small, and a package updated in place brings new
   * ones.
   */
  private File unpack() throws IOException {
    File resources = new File(getFilesDir(), "Resources");
    copy("Resources", resources);
    return resources;
  }

  private void copy(String asset, File to) throws IOException {
    String[] inside = getAssets().list(asset);
    if (inside != null && inside.length > 0) {
      to.mkdirs();
      for (String name : inside) copy(asset + "/" + name, new File(to, name));
      return;
    }
    try (InputStream in = getAssets().open(asset); OutputStream out = new FileOutputStream(to)) {
      byte[] buffer = new byte[16384];
      for (int read; (read = in.read(buffer)) > 0; ) out.write(buffer, 0, read);
    }
  }

  // MARK: - Tests

  private void test(String run) {
    TextView text = new TextView(this);
    text.setPadding(48, 48, 48, 48);
    text.setText("Driftbox");
    setContentView(text);
    if ("rack".equals(run)) {
      // On the main thread, which the rack session is on, once the view is up.
      text.post(() -> {
        String report;
        try {
          report = Native.rackCheck(unpack().getPath());
        } catch (IOException e) {
          report = "FAIL unpacking the resources: " + e;
        }
        for (String line : report.split("\n")) Log.i(TAG, line);
        Log.i(TAG, "done");
        text.setText(report);
      });
      return;
    }
    new Thread(() -> {
      String report;
      try {
        if ("gpu".equals(run)) {
          report = Native.gpuCheck();
        } else if ("text".equals(run)) {
          report = Native.textCheck();
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
