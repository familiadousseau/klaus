import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import 'audio.dart';
import 'config.dart';
import 'emotion_engine.dart';
import 'identity.dart';
import 'languages.dart';
import 'ota.dart';
import 'wake_word.dart';

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
  /// Conversa contínua (mãos livres). Ligada por defeito e lembrada entre aberturas.
  bool autoMode = true;

  /// Modo escrito: o microfone fica parado e as respostas aparecem em texto.
  bool textMode = false;

  /// No modo escrito, se true o Klaus também fala as respostas.
  bool textModeVoice = false;
  final List<ChatLine> chat = [];

  DeviceIdentity? identity;
  KlausLang lang = kLangs.first;
  int _gen = 0; // muda a cada troca de idioma, para cancelar esperas antigas
  IOWebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  String _sessionId = '';
  final MicCapture mic = MicCapture();
  final SpeakerPlayback speaker = SpeakerPlayback();
  bool _activating = false;
  bool _disposed = false;
  bool _manualHolding = false;
  final EmotionEngine _emo = EmotionEngine();

  // ---- Sono ----
  final WakeWordDetector wake = WakeWordDetector();
  bool sleeping = false;
  bool _sleepAfterReply = false;
  DateTime _selfNameUntil = DateTime(2000); // enquanto ele próprio diz "Klaus"
  bool _startAsleep = true; // ao abrir o app, espera ouvir "Klaus"
  Timer? _farewellTimer;
  bool drowsy = false;
  DateTime _lastActivity = DateTime.now();
  Timer? _sleepTimer;
  static const drowsyAfter = Duration(minutes: 2);
  static const sleepAfter = Duration(minutes: 3);
  String? _serverEmotion;
  Timer? _retry;

  double get micLevel => mic.level;
  double get speakerLevel => speaker.level;

  Timer? _watchdog;

  void _set(KlausState s, String msg) {
    state = s;
    status = msg;
    _watchdog?.cancel();
    if (s == KlausState.thinking && autoMode && !textMode) {
      _watchdog = Timer(const Duration(seconds: 20), () {
        if (!_disposed && autoMode && state == KlausState.thinking) {
          _startListening(auto: true);
        }
      });
    }
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

  /// Carinha de "em espera" enquanto o microfone está ligado mas ninguém fala.
  String _idleFace() => 'happy';

  void _onVoice(bool active) {
    if (state != KlausState.listening || drowsy) return;
    emotion = active ? 'listening' : _idleFace();
    status = active ? 'A ouvir...' : 'À espera... fale comigo';
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    mic.onVoiceChange = _onVoice;
    _sleepTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _checkSleep());
    markActivity();
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
      final prefs = await SharedPreferences.getInstance();
      lang = langByCode(prefs.getString('klaus_lang') ?? 'pt');
      _gen++;
      identity = await DeviceIdentity.load(lang.prefix);
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
    if (_startAsleep) {
      _startAsleep = false;
      await goToSleep();
      return;
    }
    await connect();
  }

  Future<void> _waitActivation(OtaClient ota, OtaResult first) async {
    if (_activating) return;
    _activating = true;
    final gen = _gen;
    try {
      var r = first;
      for (var i = 0; i < 120 && !_disposed && gen == _gen; i++) {
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
      if (_disposed || gen != _gen) return;
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
    final (url, token) = await OtaClient.savedEndpoint(identity!.prefix);
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
        if (_disposed || sleeping) return;
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
    emotion = 'happy'; // cumprimento ao ligar
    final prefs = await SharedPreferences.getInstance();
    autoMode = prefs.getBool('klaus_auto_mode') ?? true;
    if (textMode) {
      _set(KlausState.idle, 'Modo escrito');
    } else if (autoMode) {
      await _startListening(auto: true);
    } else {
      _set(KlausState.idle, 'Pronto! Toque para falar');
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (!_disposed && !sleeping && state != KlausState.needsActivation) connect();
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
      if (textMode && !textModeVoice) return; // modo escrito sem som
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
        final said = data['text']?.toString() ?? '';
        if (said.trim().length > 1) markActivity(); // frase reconhecida = conversa real
        _addChat(true, said);
        if (detectFarewell(said)) _armFarewell();
        final wanted = detectLanguageSwitch(said);
        if (wanted != null && wanted != lang.code) {
          await switchLanguage(wanted);
          return;
        }
        _set(KlausState.thinking, 'A pensar...');
        emotion = 'thinking';
        notifyListeners();
        break;
      case 'llm':
        // 👋 = a IA percebeu que é uma despedida (combinado na personalidade).
        if ((data['text']?.toString() ?? '').contains('👋')) _armFarewell();
        // O servidor só manda informação útil quando não é "feliz"/"neutro".
        final e = data['emotion']?.toString();
        if (EmotionEngine.isInformative(e)) {
          _serverEmotion = e;
          emotion = e!;
          notifyListeners();
        }
        break;
      case 'tts':
        await _onTts(data);
        break;
      case 'listen':
        break;
      case 'mcp':
        // Ferramentas do aparelho ainda não usadas no Klaus Android.
        break;
    }
  }

  Future<void> _onTts(Map<String, dynamic> data) async {
    switch (data['state']) {
      case 'start':
        markActivity();
        if (autoMode || textMode) await mic.stop();
        if (!textMode) {
          // Enquanto fala, se ouvir "Klaus" cala-se e passa a ouvir.
          try {
            await wake.start(_bargeIn);
          } catch (_) {}
        }
        _set(KlausState.speaking, textMode && !textModeVoice ? 'A escrever...' : 'A falar...');
        break;
      case 'sentence_start':
        final sentence = data['text']?.toString() ?? '';
        if (sentence.contains('👋')) _armFarewell();
        // Se a frase que ele vai dizer tem o próprio nome, não se interrompe sozinho.
        if (RegExp(r'[kc]laus', caseSensitive: false).hasMatch(sentence)) {
          final ms = 1500 + sentence.length * 90;
          _selfNameUntil = DateTime.now().add(Duration(milliseconds: ms));
        }
        _addChat(false, sentence);
        // Carinha frase a frase: o que ele diz manda; a emoção do servidor só
        // vale para a primeira frase da resposta.
        emotion = _serverEmotion ?? _emo.forSentence(sentence);
        _serverEmotion = null;
        notifyListeners();
        break;
      case 'stop':
        await speaker.drain();
        await wake.stop();
        if (_disposed) return;
        _serverEmotion = null;
        emotion = 'neutral';
        if (_sleepAfterReply) {
          await goToSleep();
          return;
        }
        if (textMode) {
          _set(KlausState.idle, 'Modo escrito');
        } else if (autoMode) {
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
    // No modo contínuo fica com a cara normal até alguém falar mesmo com ele.
    emotion = auto ? _idleFace() : 'listening';
    _set(KlausState.listening, auto ? 'À espera... fale comigo' : 'A ouvir... solte para enviar');
  }

  /// Modo manual: segurar para falar.
  Future<void> pressToTalk() async {
    markActivity();
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
    emotion = 'thinking';
    _set(KlausState.thinking, 'A pensar...');
  }

  /// Liga/desliga a conversa automática (mãos livres).
  Future<void> toggleAuto() async {
    markActivity();
    autoMode = !autoMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('klaus_auto_mode', autoMode);
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
    if (!sleeping) await wake.stop();
    _sendJson({'session_id': _sessionId, 'type': 'abort'});
    await speaker.interrupt();
    if (textMode) {
      _set(KlausState.idle, 'Modo escrito');
    } else if (autoMode) {
      await _startListening(auto: true);
    } else {
      _set(KlausState.idle, 'Pronto! Toque para falar');
    }
  }

  /// Envia uma mensagem escrita (como se tivesse sido dita).
  Future<void> sendText(String text) async {
    markActivity();
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
    emotion = 'thinking';
    _set(KlausState.thinking, 'A pensar...');
  }

  /// "Klaus" ouvido enquanto ele falava: interrompe e ouve.
  void _bargeIn() {
    if (sleeping) return;
    if (DateTime.now().isBefore(_selfNameUntil)) return; // foi ele a dizer o nome
    wake.stop();
    markActivity();
    _sleepAfterReply = false;
    abort();
  }

  /// Despedida percebida: o Klaus termina a resposta e adormece.
  void _armFarewell() {
    if (_sleepAfterReply || sleeping) return;
    _sleepAfterReply = true;
    _farewellTimer?.cancel();
    _farewellTimer = Timer(const Duration(seconds: 15), () {
      if (_sleepAfterReply && !sleeping) goToSleep();
    });
  }

  /// Regista que houve interação (adia o sono).
  void markActivity() {
    _lastActivity = DateTime.now();
    if (drowsy && !sleeping) {
      drowsy = false;
      if (state == KlausState.listening) {
        emotion = 'happy';
        status = 'À espera... fale comigo';
      }
      if (!_disposed) notifyListeners();
    }
  }

  void _checkSleep() {
    if (_disposed || sleeping || textMode) return;
    final calm = state == KlausState.idle || state == KlausState.listening;
    if (!calm) {
      return;
    }
    final idle = DateTime.now().difference(_lastActivity);
    if (idle >= sleepAfter) {
      goToSleep();
    } else if (idle >= drowsyAfter && !drowsy) {
      drowsy = true;
      emotion = 'sleepy';
      status = 'Com sono...';
      notifyListeners();
    }
  }

  /// Adormece: desliga a ligação e o envio de áudio; só fica a ouvir "Klaus".
  Future<void> goToSleep() async {
    if (sleeping) return;
    sleeping = true;
    _sleepAfterReply = false;
    _farewellTimer?.cancel();
    drowsy = false;
    if (mic.isRunning) {
      _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
      await mic.stop();
    }
    await speaker.interrupt();
    await wake.stop();
    await _closeWs();
    emotion = 'sleeping';
    _set(KlausState.idle, 'A dormir... chame "Klaus"');
    try {
      await wake.start(() => wakeUp());
    } catch (e) {
      status = 'A dormir... toque no ecrã para acordar';
      notifyListeners();
    }
  }

  /// Acorda (por "Klaus" ou toque), religa e cumprimenta.
  Future<void> wakeUp() async {
    if (!sleeping) return;
    sleeping = false;
    await wake.stop();
    markActivity();
    emotion = 'surprised';
    _set(KlausState.connecting, 'A acordar...');
    await connect();
    if (_ws != null && !textMode) {
      // Igual a um aparelho XiaoZhi que ouviu a palavra de ativação: o servidor cumprimenta.
      _sendJson({
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'detect',
        'text': 'Klaus',
      });
    }
  }

  /// Entra/sai do modo escrito.
  Future<void> setTextMode(bool on) async {
    markActivity();
    if (textMode == on) return;
    textMode = on;
    if (on) {
      textModeVoice = false;
      if (mic.isRunning) {
        await mic.stop();
        _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
      }
      await speaker.interrupt();
      if (_ws != null) _set(KlausState.idle, 'Modo escrito');
    } else {
      await speaker.interrupt();
      if (_ws != null) {
        if (autoMode) {
          await _startListening(auto: true);
        } else {
          _set(KlausState.idle, 'Pronto! Toque para falar');
        }
      }
    }
    notifyListeners();
  }

  /// No modo escrito: liga/desliga a voz do Klaus.
  Future<void> toggleTextVoice() async {
    textModeVoice = !textModeVoice;
    if (!textModeVoice) await speaker.interrupt();
    notifyListeners();
  }

  /// Troca para o Klaus de outro idioma (outro agente, com voz nativa).
  Future<void> switchLanguage(String code) async {
    final target = langByCode(code);
    if (target.code == lang.code && state != KlausState.error) return;
    markActivity();
    if (sleeping) sleeping = false;
    await wake.stop();
    _gen++;
    _activating = false;
    _sendJson({'session_id': _sessionId, 'type': 'abort'});
    await mic.stop();
    await speaker.interrupt();
    await _closeWs();
    lang = target;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('klaus_lang', lang.code);
    emotion = 'thinking';
    _set(KlausState.connecting, 'A mudar para ${lang.name} ${lang.flag}...');
    try {
      identity = await DeviceIdentity.load(lang.prefix);
      _startAsleep = false;
      await _runOta();
      if (_ws != null && !textMode) {
        // Começa logo a aula (ou o regresso) no idioma novo.
        _sendJson({
          'session_id': _sessionId,
          'type': 'listen',
          'state': 'detect',
          'text': lang.code == 'pt'
              ? 'Klaus, voltei para o português!'
              : 'Oi Klaus! Vamos treinar ${lang.name}. Começa a aula.',
        });
      }
    } catch (e) {
      _fail('Não consegui mudar de idioma: $e');
    }
  }

  Future<void> resetIdentity() async {
    await _closeWs();
    await mic.stop();
    await DeviceIdentity.reset(lang.prefix);
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
    _watchdog?.cancel();
    _sleepTimer?.cancel();
    _farewellTimer?.cancel();
    wake.dispose();
    _closeWs();
    mic.dispose();
    speaker.release();
    super.dispose();
  }
}
