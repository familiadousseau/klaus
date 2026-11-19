import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'audio.dart';
import 'config.dart';
import 'identity.dart';
import 'ota.dart';

enum KlausState { starting, needsActivation, connecting, idle, listening, thinking, speaking, error }

class ChatLine {
  final bool fromUser;
  final String text;
  ChatLine(this.fromUser, this.text);
}

/// Cérebro do app: ativação, ligação ao servidor do XiaoZhi, microfone e altifalante.
class KlausClient extends ChangeNotifier {
  KlausState state = KlausState.starting;
  String status = 'A iniciar...';
  String emotion = 'neutral';
  String? activationCode;
  String? errorText;
  bool autoMode = false;
  final List<ChatLine> chat = [];

  DeviceIdentity? identity;
  IOWebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  String _sessionId = '';
  final MicCapture mic = MicCapture();
  final SpeakerPlayback speaker = SpeakerPlayback();
  bool _activating = false;
  bool _disposed = false;
  bool _manualHolding = false;
  Timer? _retry;

  double get micLevel => mic.level;
  double get speakerLevel => speaker.level;

  void _set(KlausState s, String msg) {
    state = s;
    status = msg;
    if (!_disposed) notifyListeners();
  }

  void _addChat(bool user, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    chat.add(ChatLine(user, t));
    if (chat.length > 60) chat.removeAt(0);
    if (!_disposed) notifyListeners();
  }

  // ---------------- arranque e ativação ----------------

  Future<void> start() async {
    errorText = null;
    _set(KlausState.starting, 'A preparar o Klaus...');
    try {
      await SpeakerPlayback.configureSession();
      final ok = await MicCapture.ensurePermission();
      if (!ok) {
        errorText = 'Preciso da permissão do microfone para conversar.';
        _set(KlausState.error, 'Sem microfone');
        return;
      }
      identity = await DeviceIdentity.load();
      await _runOta();
    } catch (e) {
      _fail('Não consegui falar com o servidor: $e');
    }
  }

  Future<void> _runOta() async {
    final ota = OtaClient(identity!);
    _set(KlausState.starting, 'A contactar o servidor...');
    final r = await ota.fetch();
    if (r.needsActivation) {
      activationCode = r.activationCode;
      _set(KlausState.needsActivation, 'Falta ativar este telemóvel');
      _waitActivation(ota, r);
      return;
    }
    activationCode = null;
    await connect();
  }

  Future<void> _waitActivation(OtaClient ota, OtaResult first) async {
    if (_activating) return;
    _activating = true;
    try {
      var r = first;
      for (var i = 0; i < 120 && !_disposed; i++) {
        await Future.delayed(const Duration(seconds: 5));
        if (r.challenge != null && r.challenge!.isNotEmpty) {
          try {
            if (await ota.tryActivate(r.challenge!)) break;
          } catch (_) {}
        }
        try {
          r = await ota.fetch();
          if (!r.needsActivation) break;
          if (r.activationCode != activationCode) {
            activationCode = r.activationCode;
            notifyListeners();
          }
        } catch (_) {}
      }
      if (_disposed) return;
      final again = await ota.fetch();
      if (again.needsActivation) {
        activationCode = again.activationCode;
        _set(KlausState.needsActivation, 'Ainda não ativado. Toque em "Tentar de novo".');
        return;
      }
      activationCode = null;
      await connect();
    } catch (e) {
      _fail('Erro na ativação: $e');
    } finally {
      _activating = false;
    }
  }

  // ---------------- ligação WebSocket ----------------

  Future<void> connect() async {
    await _closeWs();
    final (url, token) = await OtaClient.savedEndpoint();
    if (url == null) {
      _fail('O servidor não indicou o endereço de ligação.');
      return;
    }
    _set(KlausState.connecting, 'A ligar ao Klaus...');
    final id = identity!;
    try {
      final socket = await WebSocket.connect(url, headers: {
        'Authorization': 'Bearer ${token ?? 'test-token'}',
        'Protocol-Version': '1',
        'Device-Id': id.deviceId,
        'Client-Id': id.clientId,
      }).timeout(const Duration(seconds: 10));
      socket.pingInterval = const Duration(seconds: 20);
      _ws = IOWebSocketChannel(socket);
    } catch (e) {
      _fail('Não consegui ligar: $e');
      _scheduleReconnect();
      return;
    }

    final helloDone = Completer<bool>();
    _wsSub = _ws!.stream.listen(
      (msg) => _onMessage(msg, helloDone),
      onError: (e) {
        _fail('Ligação caiu: $e');
        _scheduleReconnect();
      },
      onDone: () {
        if (_disposed) return;
        mic.stop();
        if (state != KlausState.error) _set(KlausState.connecting, 'Ligação fechada, a religar...');
        _scheduleReconnect();
      },
    );

    _sendJson({
      'type': 'hello',
      'version': 1,
      'features': {'mcp': false},
      'transport': 'websocket',
      'audio_params': {
        'format': 'opus',
        'sample_rate': KlausConfig.inputSampleRate,
        'channels': KlausConfig.channels,
        'frame_duration': KlausConfig.frameDurationMs,
      },
    });

    final ok = await helloDone.future
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ok) {
      _fail('O servidor não respondeu ao "olá".');
      _scheduleReconnect();
      return;
    }
    _set(KlausState.idle, 'Pronto! Toque para falar');
    emotion = 'happy';
    notifyListeners();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (!_disposed && state != KlausState.needsActivation) connect();
    });
  }

  Future<void> _closeWs() async {
    _retry?.cancel();
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
  }

  void _sendJson(Map<String, dynamic> m) {
    try {
      _ws?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<void> _onMessage(dynamic msg, Completer<bool> helloDone) async {
    if (msg is List<int>) {
      speaker.addOpus(Uint8List.fromList(msg));
      return;
    }
    if (msg is! String) return;
    Map<String, dynamic> data;
    try {
      data = jsonDecode(msg) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (data['type']) {
      case 'hello':
        _sessionId = data['session_id']?.toString() ?? '';
        var rate = 24000;
        final ap = data['audio_params'];
        if (ap is Map && ap['sample_rate'] is int) rate = ap['sample_rate'] as int;
        await speaker.setup(rate);
        if (!helloDone.isCompleted) helloDone.complete(true);
        break;
      case 'stt':
        _addChat(true, data['text']?.toString() ?? '');
        _set(KlausState.thinking, 'A pensar...');
        emotion = 'thinking';
        notifyListeners();
        break;
      case 'llm':
        final e = data['emotion']?.toString();
        if (e != null && e.isNotEmpty) {
          emotion = e;
          notifyListeners();
        }
        break;
      case 'tts':
        await _onTts(data);
        break;
      case 'mcp':
        // Ferramentas do aparelho ainda não usadas no Klaus Android.
        break;
    }
  }

  Future<void> _onTts(Map<String, dynamic> data) async {
    switch (data['state']) {
      case 'start':
        if (autoMode) await mic.stop();
        _set(KlausState.speaking, 'A falar...');
        break;
      case 'sentence_start':
        _addChat(false, data['text']?.toString() ?? '');
        break;
      case 'stop':
        await speaker.drain();
        if (_disposed) return;
        if (autoMode) {
          await _startListening(auto: true);
        } else {
          _set(KlausState.idle, 'Pronto! Toque para falar');
        }
        break;
    }
  }

  // ---------------- conversa ----------------

  Future<void> _startListening({required bool auto}) async {
    if (_ws == null) return;
    if (speaker.isBusy) await speaker.interrupt();
    _sendJson({
      'session_id': _sessionId,
      'type': 'listen',
      'state': 'start',
      'mode': auto ? 'auto' : 'manual',
    });
    await mic.start((opus) {
      try {
        _ws?.sink.add(opus);
      } catch (_) {}
    });
    _set(KlausState.listening, auto ? 'A ouvir (automático)...' : 'A ouvir... solte para enviar');
  }

  /// Modo manual: segurar para falar.
  Future<void> pressToTalk() async {
    if (state == KlausState.speaking) await abort();
    if (_ws == null) return;
    _manualHolding = true;
    await _startListening(auto: false);
  }

  Future<void> releaseToTalk() async {
    if (!_manualHolding) return;
    _manualHolding = false;
    await mic.stop();
    _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
    _set(KlausState.thinking, 'A pensar...');
  }

  /// Liga/desliga a conversa automática (mãos livres).
  Future<void> toggleAuto() async {
    autoMode = !autoMode;
    if (autoMode) {
      await _startListening(auto: true);
    } else {
      await mic.stop();
      _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
      await abort();
      _set(KlausState.idle, 'Pronto! Toque para falar');
    }
    notifyListeners();
  }

  Future<void> abort() async {
    _sendJson({'session_id': _sessionId, 'type': 'abort'});
    await speaker.interrupt();
    if (!autoMode) _set(KlausState.idle, 'Pronto! Toque para falar');
  }

  /// Envia uma mensagem escrita (como se tivesse sido dita).
  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || _ws == null) return;
    if (state == KlausState.speaking) await abort();
    _addChat(true, t);
    _sendJson({
      'session_id': _sessionId,
      'type': 'listen',
      'state': 'detect',
      'text': t,
    });
    _set(KlausState.thinking, 'A pensar...');
  }

  Future<void> resetIdentity() async {
    await _closeWs();
    await mic.stop();
    await DeviceIdentity.reset();
    chat.clear();
    await start();
  }

  void _fail(String msg) {
    errorText = msg;
    emotion = 'sad';
    _set(KlausState.error, 'Algo correu mal');
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _closeWs();
    mic.dispose();
    speaker.release();
    super.dispose();
  }
}
