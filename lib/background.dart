import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Modo bolso": o Klaus continua a ouvir com o ecrã bloqueado (serviço em primeiro plano
/// com a notificação "Klaus está a ouvir") e, quando o chamam, acende o ecrã e mostra a
/// carinha por cima do bloqueio. A parte nativa está em KlausService.kt e MainActivity.kt.
class KlausBackground {
  static const _ch = MethodChannel('klaus/service');
  static const _prefKey = 'klaus_bg_enabled';
  static const _fsiAskedKey = 'klaus_fsi_asked';

  bool enabled = true;
  bool running = false;
  void Function()? onStopped;

  KlausBackground() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'serviceStopped') {
        running = false;
        onStopped?.call();
      }
      return null;
    });
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_prefKey) ?? true;
  }

  /// Liga o modo bolso (só funciona com o app aberto e o microfone autorizado).
  Future<void> start() async {
    if (!enabled || running) return;
    if (!await Permission.microphone.isGranted) return;
    await Permission.notification.request(); // Android 13+: para a notificação aparecer
    try {
      running = await _ch.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      running = false;
    }
  }

  Future<void> stop() async {
    running = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, on);
    if (on) {
      await start();
    } else {
      await stop();
    }
  }

  /// O Klaus acordou: se o ecrã estiver bloqueado/apagado, acende-o e mostra a carinha.
  Future<void> showOnLock() async {
    try {
      await _ch.invokeMethod('showOnLock');
    } catch (_) {}
  }

  /// O Klaus voltou a dormir: o bloqueio volta a ficar por cima.
  Future<void> releaseLock() async {
    try {
      await _ch.invokeMethod('releaseLock');
    } catch (_) {}
  }

  /// Android 14+: a permissão "notificações em ecrã inteiro" (precisa para a carinha
  /// aparecer por cima do bloqueio quando o Klaus estava na janelinha). Pergunta uma vez.
  Future<bool> needsFullScreenPermission() async {
    try {
      final ok = await _ch.invokeMethod<bool>('canFullScreen') ?? true;
      if (ok) return false;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_fsiAskedKey) ?? false) return false;
      await prefs.setBool(_fsiAskedKey, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> openFullScreenSettings() async {
    try {
      await _ch.invokeMethod('openFullScreenSettings');
    } catch (_) {}
  }
}
