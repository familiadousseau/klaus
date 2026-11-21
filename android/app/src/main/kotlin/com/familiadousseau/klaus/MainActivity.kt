package com.familiadousseau.klaus

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import android.view.WindowManager
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Janelinha flutuante (Picture-in-Picture), como o Maps: ao sair do app o Klaus fica
 * num quadradinho com a carinha (GIF 240×240 → proporção 1:1) por cima das outras apps.
 */
class MainActivity : FlutterActivity() {
    private val actionName = "com.familiadousseau.klaus.PIP_ACTION"
    private var channel: MethodChannel? = null
    private var pipEnabled = false
    private var sleeping = false
    private var radioPlaying = false
    private var serviceChannel: MethodChannel? = null
    private var lockShown = false
    private val wakeNotificationId = 42

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.getStringExtra("action") ?: return
            channel?.invokeMethod("pipAction", action)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.getBooleanExtra("klaus_lock", false) == true) applyLockFlags(true)
        val filter = IntentFilter(actionName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Modo bolso (ouvir com o ecrã bloqueado) e carinha por cima do bloqueio.
        val sc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "klaus/service")
        serviceChannel = sc
        KlausService.onStopped = { runOnUiThread { sc.invokeMethod("serviceStopped", null) } }
        sc.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(KlausService.start(this))
                "stop" -> {
                    KlausService.stop(this)
                    result.success(null)
                }
                "showOnLock" -> {
                    showOnLock()
                    result.success(null)
                }
                "releaseLock" -> {
                    releaseLock()
                    result.success(null)
                }
                "canFullScreen" -> result.success(canFullScreen())
                "openFullScreenSettings" -> {
                    openFullScreenSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "klaus/pip")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(pipSupported())
                "update" -> {
                    pipEnabled = call.argument<Boolean>("enabled") ?: false
                    sleeping = call.argument<Boolean>("sleeping") ?: false
                    radioPlaying = call.argument<Boolean>("radio") ?: false
                    applyParams()
                    result.success(null)
                }
                "enter" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        }
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun action(id: String, title: String, icon: Int, request: Int): RemoteAction? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val intent = Intent(actionName).setPackage(packageName).putExtra("action", id)
        val pending = PendingIntent.getBroadcast(
            this, request, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(Icon.createWithResource(this, icon), title, title, pending)
    }

    private fun buildParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val actions = ArrayList<RemoteAction>()
        // 🎤 acordar / adormecer
        action(
            if (sleeping) "wake" else "sleep",
            if (sleeping) "Acordar" else "Dormir",
            if (sleeping) android.R.drawable.ic_btn_speak_now else android.R.drawable.ic_lock_idle_lock,
            1,
        )?.let { actions.add(it) }
        // ⏹ parar a rádio (só aparece quando está a tocar)
        if (radioPlaying) {
            action("radio_stop", "Parar rádio", android.R.drawable.ic_media_pause, 2)?.let { actions.add(it) }
        }
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(1, 1)) // igual ao GIF da carinha (240×240)
            .setActions(actions)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled) // Android 12+: entra sozinho ao sair
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun applyParams() {
        if (!pipSupported()) return
        try {
            buildParams()?.let { setPictureInPictureParams(it) }
        } catch (_: Exception) {
        }
    }

    private fun enterPip(): Boolean {
        if (!pipSupported()) return false
        return try {
            buildParams()?.let { enterPictureInPictureMode(it) } ?: false
        } catch (_: Exception) {
            false
        }
    }

    // ----------------------------------------------------------------------------------
    // Carinha por cima do ecrã bloqueado quando se chama "Klaus"
    // ----------------------------------------------------------------------------------

    private fun applyLockFlags(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(f) else window.clearFlags(f)
        }
    }

    private fun showOnLock() {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!km.isKeyguardLocked && pm.isInteractive) return // desbloqueado: nada a fazer
        lockShown = true
        applyLockFlags(true)
        // Acende o ecrã.
        try {
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "klaus:acordar",
            )
            wl.acquire(5000)
        } catch (_: Exception) {
        }
        // Traz o Klaus para a frente por cima do bloqueio (mesmo que estivesse na janelinha).
        postWakeNotification()
    }

    private fun releaseLock() {
        if (!lockShown) return
        lockShown = false
        applyLockFlags(false) // o bloqueio volta a aparecer por cima
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(wakeNotificationId)
    }

    private fun postWakeNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel("klaus_wake", "Klaus acordou", NotificationManager.IMPORTANCE_HIGH)
                ch.setSound(null, null)
                ch.enableVibration(false)
                nm.createNotificationChannel(ch)
            }
            val intent = Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("klaus_lock", true)
            val pending = PendingIntent.getActivity(
                this, 5, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, "klaus_wake")
            else Notification.Builder(this)
            val n = builder
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("Klaus")
                .setContentText("Estou a ouvir!")
                .setCategory(Notification.CATEGORY_ALARM)
                .setFullScreenIntent(pending, true)
                .setAutoCancel(true)
                .build()
            nm.notify(wakeNotificationId, n)
        } catch (_: Exception) {
        }
    }

    private fun canFullScreen(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    private fun openFullScreenSettings() {
        if (Build.VERSION.SDK_INT < 34) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")),
            )
        } catch (_: Exception) {
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("klaus_lock", false)) {
            applyLockFlags(true)
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(wakeNotificationId)
        }
    }

    override fun onResume() {
        super.onResume()
        if (lockShown) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(wakeNotificationId)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 8 a 11: entra na janelinha ao carregar no botão de início.
        if (pipEnabled && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }
}
