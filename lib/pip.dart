import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Janelinha flutuante (Picture-in-Picture do Android), como o Maps.
/// A parte nativa está em MainActivity.kt.
class KlausPip extends ChangeNotifier {
  static const _ch = MethodChannel('klaus/pip');
  static const _prefKey = 'klaus_pip_enabled';

  /// O telemóvel suporta janelinha (Android 8+).
  bool supported = false;

  /// Entrar na janelinha ao sair do app.
  bool enabled = true;

  /// Está agora na janelinha.
  bool inPip = false;

  /// Botões da janelinha: 'wake', 'sleep', 'radio_stop'.
  void Function(String action)? onAction;

  bool? _lastSleeping;
  bool? _lastRadio;

  KlausPip() {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pipChanged':
          inPip = call.arguments == true;
          notifyListeners();
          break;
        case 'pipAction':
          onAction?.call(call.arguments.toString());
          break;
      }
      return null;
    });
  }

  Future<void> init() async {
    try {
      supported = await _ch.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      supported = false;
    }
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_prefKey) ?? true;
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, on);
    _lastSleeping = null; // força atualizar
    notifyListeners();
  }

  /// Avisa a parte nativa do estado (só quando muda).
  Future<void> sync({required bool sleeping, required bool radio}) async {
    if (!supported) return;
    if (_lastSleeping == sleeping && _lastRadio == radio) return;
    _lastSleeping = sleeping;
    _lastRadio = radio;
    try {
      await _ch.invokeMethod('update', {'enabled': enabled, 'sleeping': sleeping, 'radio': radio});
    } catch (_) {}
  }

  /// Entra já na janelinha (botão no app).
  Future<bool> enter() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }
}
