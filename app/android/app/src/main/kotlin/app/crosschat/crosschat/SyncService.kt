package app.crosschat.crosschat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Opt-in "keep connection open" mode (Settings → Background sync).
 *
 * Instead of push notifications, Crosschat can keep its Matrix /sync
 * connection alive. This foreground service keeps the app process (and the
 * Rust core's sync loop running inside it) from being frozen while the app
 * is in the background. It shows a low-importance ongoing notification, as
 * Android requires.
 *
 * Alpha limitation: the sync loop lives in the Flutter engine owned by the
 * activity, so swiping the app away from recents stops syncing. Moving the
 * loop into the service (headless engine or Rust-only) is on the roadmap.
 */
class SyncService : Service() {
    companion object {
        const val CHANNEL_ID = "crosschat_sync"
        const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, SyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SyncService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(CHANNEL_ID, "Connection", NotificationManager.IMPORTANCE_MIN)
                ch.description = "Keeps Crosschat connected so messages arrive without push"
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Crosschat is connected")
            .setContentText("Keeping your chats in sync")
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}
