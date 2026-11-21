package com.familiadousseau.klaus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * "Modo bolso": serviço em primeiro plano com a notificação "Klaus está a ouvir".
 * Mantém o microfone e o app vivos com o ecrã bloqueado, para o Klaus ouvir "Klaus".
 * O trabalho (ouvir, conversar) continua no Flutter; o serviço só o mantém acordado.
 */
class KlausService : Service() {
    companion object {
        const val ACTION_STOP = "com.familiadousseau.klaus.STOP_LISTENING"
        private const val CHANNEL = "klaus_listen"
        private const val NOTIFICATION_ID = 41

        /** Chamado quando a pessoa carrega em "Parar" na notificação. */
        var onStopped: (() -> Unit)? = null
        var running = false

        fun start(ctx: Context): Boolean {
            return try {
                val intent = Intent(ctx, KlausService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(intent)
                else ctx.startService(intent)
                true
            } catch (_: Exception) {
                false
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, KlausService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            onStopped?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = buildNotification()
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> startForeground(
                    NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
                else -> startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // O Android não deixou (p. ex. app em segundo plano): desiste sem rebentar.
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "klaus:ouvir").apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L) // no máximo 12 h seguidas
            }
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL, "Klaus a ouvir", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, KlausService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL)
        else Notification.Builder(this)
        builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Klaus está a ouvir")
            .setContentText("Diga «Klaus», mesmo com o ecrã bloqueado")
            .setOngoing(true)
            .setContentIntent(open)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel), "Parar", stop,
                ).build(),
            )
        }
        return builder.build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App fechado nas recentes: deixa de ouvir.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }
}
