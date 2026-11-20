package com.familiadousseau.klaus

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

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.getStringExtra("action") ?: return
            channel?.invokeMethod("pipAction", action)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
