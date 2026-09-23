package app.driftbox;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.os.IBinder;

/**
 * What keeps a song playing with the app out of view. It does nothing itself: the song plays in
 * the app's own process, and this only says to Android that it is. That matters because of where
 * Android puts a process. In view, the app is in the top-app cpuset, with every core; out of view,
 * and with nothing like this running, it is moved to the background cpuset, which on a Fairphone 6
 * is the four little cores alone, and there the audio's render thread cannot keep up. A foreground
 * service of the media playback kind keeps the process in the foreground cpuset, with the big
 * cores, for as long as it runs; and Android wants a notification for it, which says what is
 * playing, opens the app, and stops it.
 *
 * Started by the app while it is in view, since Android will not let a background app start one.
 */
public final class Playback extends Service {
  static final String STOP = "app.driftbox.STOP";
  private static final String CHANNEL = "playing";

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null && STOP.equals(intent.getAction())) {
      Main.stopPlaying();
      stopSelf();
      return START_NOT_STICKY;
    }
    String song = intent == null ? null : intent.getStringExtra("song");
    NotificationManager notifications = getSystemService(NotificationManager.class);
    notifications.createNotificationChannel(
        new NotificationChannel(CHANNEL, "Playing", NotificationManager.IMPORTANCE_LOW));
    PendingIntent open = PendingIntent.getActivity(
        this, 0, new Intent(this, Main.class), PendingIntent.FLAG_IMMUTABLE);
    PendingIntent stop = PendingIntent.getService(
        this, 1, new Intent(this, Playback.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
    Notification notification = new Notification.Builder(this, CHANNEL)
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setContentTitle("Driftbox")
        .setContentText(song == null ? "Playing" : "Playing " + song)
        .setContentIntent(open)
        .setOngoing(true)
        .addAction(new Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_pause), "Stop", stop).build())
        .build();
    startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
    return START_NOT_STICKY;
  }

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }
}
