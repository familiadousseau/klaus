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

/// Estados do Klaus.
/// standby  = em descanso: só ouve "Klaus", sem ligação nem envio de áudio.
/// waiting  = acordado, à espera que você fale (janela de conversa).
/// listening= você está a falar; o áudio vai para o servidor.
enum KlausState {
  starting,
  needsActivation,
  error,
  standby,
  connecting,
  waiting,
  listening,
  thinking,
  speaking,
  textIdle,
}

class ChatLine {
  final bool fromUser;
  final String text;
  ChatLine(this.fromUser, this.text);
}

/// Cérebro do app. Funciona como uma placa XiaoZhi ESP32:
/// palavra "Klaus" no aparelho -> conversa -> silêncio -> descanso.
class KlausClient extends ChangeNotifier {
  KlausState state = KlausState.starting;
  String status = 'A iniciar...';
  String emotion = 'neutral';
  String? activationCode;
  String? errorText;

  /// Modo escrito: o microfone fica parado e as respostas aparecem em texto.
  bool textMode = false;
  bool textModeVoice = false;
  final List<ChatLine> chat = [];

  DeviceIdentity? identity;
  KlausLang lang = kLangs.first;

  final MicHub mic = MicHub();
  final SpeakerPlayback speaker = SpeakerPlayback();
  final WakeWordEngine wake = WakeWordEngine();
  final EmotionEngine _emo = EmotionEngine();

  // ---- Definições (guardadas no telemóvel) ----
  String wakeSensitivity = 'normal';
  String micSensitivity = 'normal';
  String pauseLength = 'normal';

  /// Tempo à espera de nova fala depois de uma resposta, antes de descansar.
  static const followUpWindow = Duration(seconds: 12);

  /// Em descanso há mais de isto: ecrã preto (sono profundo).
  static const deepSleepAfter = Duration(seconds: 60);

  // ---- Ligação ----
  IOWebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  String _sessionId = '';
  Completer<bool>? _connecting;
  bool get _connected => _ws != null && _sessionId.isNotEmpty;

  // ---- Conversa ----
  final List<Int16List> _preRoll = []; // últimos ~360 ms antes de a voz começar
  final List<Int16List> _segFrames = []; // frase a aguardar ligação
  bool _segActive = false;
  bool _segReady = false;
  bool _segForced = false; // botão "segure para falar"
  Future<void>? _segBegin;
  DateTime _segStart = DateTime.now();

  Timer? _followUpTimer;
  Timer? _deepTimer;
  Timer? _thinkTimer;
  Timer? _greetTimer;
  Timer? _farewellTimer;
  bool deepSleep = false;
  bool _sleepAfterReply = false;
  DateTime _selfNameUntil = DateTime(2000);
  String? _serverEmotion;
  int _gen = 0;
  bool _activating = false;
  bool _disposed = false;

  bool get sleeping => state == KlausState.standby;
  double get micLevel => mic.level;
  double get speakerLevel => speaker.level;

  // ======================================================================
  // Utilitários
  // ======================================================================

  void _set(KlausState s, String msg) {
    state = s;
    status = msg;
    if (!_disposed) notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _addChat(bool user, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    chat.add(ChatLine(user, t));
    if (chat.length > 60) chat.removeAt(0);
    _notify();
  }

  void _sendJson(Map<String, dynamic> m) {
    try {
      _ws?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _sendAudio(Int16List pcm) {
    try {
      _ws?.sink.add(mic.encode(pcm));
    } catch (_) {}
  }

  void _cancelTimers() {
    _followUpTimer?.cancel();
    _deepTimer?.cancel();
    _thinkTimer?.cancel();
    _greetTimer?.cancel();
  }

  /// Compatibilidade com a interface (toques no ecrã).
  void markActivity() {
    if (state == KlausState.waiting) _armFollowUp();
  }

  // ======================================================================
  // Arranque e ativação
  // ======================================================================

  Future<void> start() async {
    errorText = null;
    _gen++;
    _set(KlausState.starting, 'A preparar o Klaus...');
    try {
      await SpeakerPlayback.configureSession();
      if (!await MicHub.ensurePermission()) {
        errorText = 'Preciso da permissão do microfone para conversar.';
        _set(KlausState.error, 'Sem microfone');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      lang = langByCode(prefs.getString('klaus_lang') ?? 'pt');
      wakeSensitivity = prefs.getString('klaus_wake_sens') ?? 'normal';
      micSensitivity = prefs.getString('klaus_mic_sens') ?? 'normal';
      pauseLength = prefs.getString('klaus_pause') ?? 'normal';
      mic.setSensitivity(micSensitivity);
      mic.setPause(pauseLength);
      mic.onFrame = _onFrame;
      mic.onVoiceChange = _onVoiceChange;

      _set(KlausState.starting, 'A preparar o ouvido do Klaus...');
      await wake.init();
      wake.setSensitivity(wakeSensitivity);

      identity = await DeviceIdentity.load(lang.prefix);
      await _runOta(thenStandby: true);
    } catch (e) {
      _fail('Não consegui arrancar: $e');
    }
  }

  Future<void> _runOta({required bool thenStandby}) async {
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
    await _afterActivation(thenStandby: thenStandby);
  }

  Future<void> _afterActivation({required bool thenStandby}) async {
    if (!textMode) await mic.start();
    if (textMode) {
      _set(KlausState.textIdle, 'Modo escrito');
      await _ensureConnected();
    } else if (thenStandby) {
      await _enterStandby();
    }
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
            _notify();
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
      await _afterActivation(thenStandby: true);
    } catch (e) {
      _fail('Erro na ativação: $e');
    } finally {
      _activating = false;
    }
  }

  // ======================================================================
  // Ligação ao servidor (só quando é preciso)
  // ======================================================================

  Future<bool> _ensureConnected() async {
    if (_connected) return true;
    if (_connecting != null) return _connecting!.future;
    final c = Completer<bool>();
    _connecting = c;
    var ok = false;
    try {
      ok = await _openWs();
    } catch (_) {
      ok = false;
    }
    _connecting = null;
    c.complete(ok);
    return ok;
  }

  Future<bool> _openWs() async {
    await _closeWs();
    final (url, token) = await OtaClient.savedEndpoint(identity!.prefix);
    if (url == null) return false;
    final id = identity!;
    final socket = await WebSocket.connect(url, headers: {
      'Authorization': 'Bearer ${token ?? 'test-token'}',
      'Protocol-Version': '1',
      'Device-Id': id.deviceId,
      'Client-Id': id.clientId,
    }).timeout(const Duration(seconds: 10));
    socket.pingInterval = const Duration(seconds: 20);
    final ws = IOWebSocketChannel(socket);
    _ws = ws;
    final hello = Completer<bool>();
    _wsSub = ws.stream.listen(
      (msg) => _onMessage(msg, hello),
      onError: (_) => _onWsClosed(ws),
      onDone: () => _onWsClosed(ws),
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
    final ok = await hello.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ok) await _closeWs();
    return ok;
  }

  void _onWsClosed(IOWebSocketChannel which) {
    if (!identical(which, _ws)) return;
    _ws = null;
    _sessionId = '';
    _wsSub = null;
    if (_disposed) return;
    // A meio de uma conversa: volta a esperar; a próxima fala volta a ligar.
    if (state == KlausState.thinking || state == KlausState.speaking) {
      speaker.interrupt();
      _enterWaiting();
    }
  }

  Future<void> _closeWs() async {
    final sub = _wsSub;
    final ws = _ws;
    _wsSub = null;
    _ws = null;
    _sessionId = '';
    await sub?.cancel();
    try {
      await ws?.sink.close();
    } catch (_) {}
  }

  // ======================================================================
  // Microfone: um único fluxo, decidido pelo estado
  // ======================================================================

  void _onFrame(Int16List pcm) {
    switch (state) {
      case KlausState.standby:
        // Em descanso: só procura "Klaus". Nada sai do telemóvel.
        if (wake.feed(pcm)) _onWakeWord();
        _keepPreRoll(pcm);
        break;
      case KlausState.waiting:
        _keepPreRoll(pcm);
        break;
      case KlausState.listening:
        if (!_segActive) break;
        if (_segReady) {
          _sendAudio(pcm);
        } else {
          _segFrames.add(pcm);
          if (_segFrames.length > 170) _segFrames.removeAt(0); // máx. ~10 s
        }
        // Segurança: frases muito longas terminam sozinhas.
        if (!_segForced && DateTime.now().difference(_segStart).inSeconds > 30) {
          _endSegment();
        }
        break;
      case KlausState.thinking:
      case KlausState.speaking:
        // Enquanto pensa ou fala, "Klaus" interrompe.
        if (wake.feed(pcm)) _bargeIn();
        _keepPreRoll(pcm);
        break;
      default:
        break;
    }
  }

  void _keepPreRoll(Int16List pcm) {
    _preRoll.add(pcm);
    if (_preRoll.length > 6) _preRoll.removeAt(0);
  }

  void _onVoiceChange(bool active) {
    if (_segForced) return;
    if (active && state == KlausState.waiting) {
      _beginSegment();
    } else if (!active && state == KlausState.listening && _segActive) {
      _endSegment();
    }
  }

  // ======================================================================
  // Descanso, acordar e janela de conversa
  // ======================================================================

  Future<void> _enterStandby({bool deep = false}) async {
    _cancelTimers();
    _farewellTimer?.cancel();
    _sleepAfterReply = false;
    _segActive = false;
    _segFrames.clear();
    await speaker.interrupt();
    await _closeWs(); // sem ligação em descanso: poupa bateria e dados
    wake.reset();
    deepSleep = deep;
    emotion = deep ? 'sleeping' : 'relaxed';
    _set(
      KlausState.standby,
      wake.ready ? 'Em descanso... chame "Klaus"' : 'Em descanso... toque no ecrã',
    );
    if (!deep) {
      _deepTimer = Timer(deepSleepAfter, () {
        if (state == KlausState.standby) {
          deepSleep = true;
          emotion = 'sleeping';
          _notify();
        }
      });
    }
  }

  /// Ouviu "Klaus" em descanso.
  void _onWakeWord() {
    _wake(greetIfSilent: true);
  }

  /// Acordar por toque no ecrã.
  Future<void> wakeUp() async {
    if (state != KlausState.standby) return;
    _wake(greetIfSilent: true);
  }

  void _wake({required bool greetIfSilent}) {
    _cancelTimers();
    deepSleep = false;
    emotion = 'surprised';
    _set(KlausState.waiting, 'Sim? Pode falar');
    Timer(const Duration(milliseconds: 700), () {
      if (state == KlausState.waiting && emotion == 'surprised') {
        emotion = 'happy';
        _notify();
      }
    });
    _armFollowUp();
    _ensureConnected(); // liga já, em paralelo com a sua fala
    // Se continuou a falar logo a seguir a "Klaus" ("Klaus, conta uma piada"), apanha tudo.
    if (mic.voiceActive) {
      _beginSegment();
      return;
    }
    if (greetIfSilent) {
      // Se não disser mais nada logo a seguir, o Klaus cumprimenta.
      _greetTimer = Timer(const Duration(milliseconds: 1500), () async {
        if (state != KlausState.waiting) return;
        if (!await _ensureConnected()) return;
        if (state != KlausState.waiting) return;
        _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'detect', 'text': 'Klaus'});
        emotion = 'thinking';
        _set(KlausState.thinking, 'A pensar...');
        _armThinkTimeout();
      });
    }
  }

  void _armFollowUp() {
    _followUpTimer?.cancel();
    _followUpTimer = Timer(followUpWindow, () {
      if (state == KlausState.waiting && !_segActive) _enterStandby();
    });
  }

  void _armThinkTimeout() {
    _thinkTimer?.cancel();
    _thinkTimer = Timer(const Duration(seconds: 15), () {
      if (state == KlausState.thinking) _enterWaiting();
    });
  }

  /// Volta a ouvir (janela de conversa aberta).
  void _enterWaiting() {
    if (textMode) {
      _set(KlausState.textIdle, 'Modo escrito');
      return;
    }
    _thinkTimer?.cancel();
    wake.reset();
    emotion = 'happy';
    _set(KlausState.waiting, 'À escuta... pode falar');
    _armFollowUp();
    // Se já estiver a falar (ex.: logo depois de "Klaus"), apanha a frase.
    if (mic.voiceActive) _beginSegment();
  }

  // ======================================================================
  // Uma frase sua -> servidor
  // ======================================================================

  void _beginSegment({bool forced = false}) {
    if (_segActive) return;
    _greetTimer?.cancel();
    _followUpTimer?.cancel();
    _segActive = true;
    _segReady = false;
    _segForced = forced;
    _segStart = DateTime.now();
    _segFrames
      ..clear()
      ..addAll(_preRoll);
    _preRoll.clear();
    emotion = 'listening';
    _set(KlausState.listening, forced ? 'A ouvir... solte para enviar' : 'A ouvir...');
    _segBegin = () async {
      final ok = await _ensureConnected();
      if (!_segActive) return;
      if (!ok) {
        _segActive = false;
        _segFrames.clear();
        emotion = 'sad';
        _set(KlausState.waiting, 'Sem ligação ao servidor... tente de novo');
        _armFollowUp();
        return;
      }
      _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'start', 'mode': 'manual'});
      while (_segFrames.isNotEmpty) {
        _sendAudio(_segFrames.removeAt(0));
      }
      _segReady = true;
    }();
  }

  Future<void> _endSegment() async {
    if (!_segActive) return;
    await _segBegin;
    if (!_segActive) return;
    _segActive = false;
    _segForced = false;
    _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
    emotion = 'thinking';
    _set(KlausState.thinking, 'A pensar...');
    _armThinkTimeout();
  }

  /// Botão "segure para falar" (funciona também em descanso).
  Future<void> pressToTalk() async {
    if (textMode) return;
    if (state == KlausState.speaking || state == KlausState.thinking) await abort();
    if (state == KlausState.standby) {
      _cancelTimers();
      deepSleep = false;
    }
    _segActive = false;
    _beginSegment(forced: true);
  }

  Future<void> releaseToTalk() async {
    if (!_segForced) return;
    await _endSegment();
  }

  // ======================================================================
  // Mensagens do servidor
  // ======================================================================

  Future<void> _onMessage(dynamic msg, Completer<bool> hello) async {
    if (msg is List<int>) {
      if (textMode && !textModeVoice) return;
      if (state == KlausState.standby) return;
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
        if (!hello.isCompleted) hello.complete(true);
        break;

      case 'stt':
        final said = (data['text']?.toString() ?? '').trim();
        if (said.length < 2) {
          // Ruído sem palavras: ignora e volta a ouvir.
          if (state == KlausState.thinking) _enterWaiting();
          return;
        }
        _addChat(true, said);
        if (detectFarewell(said)) _armFarewell();
        final wanted = detectLanguageSwitch(said);
        if (wanted != null && wanted != lang.code) {
          await switchLanguage(wanted);
          return;
        }
        emotion = 'thinking';
        _set(KlausState.thinking, 'A pensar...');
        _armThinkTimeout();
        break;

      case 'llm':
        if ((data['text']?.toString() ?? '').contains('👋')) _armFarewell();
        final e = data['emotion']?.toString();
        if (EmotionEngine.isInformative(e)) {
          _serverEmotion = e;
          emotion = e!;
          _notify();
        }
        break;

      case 'tts':
        await _onTts(data);
        break;
    }
  }

  Future<void> _onTts(Map<String, dynamic> data) async {
    if (state == KlausState.standby) return;
    switch (data['state']) {
      case 'start':
        _thinkTimer?.cancel();
        _followUpTimer?.cancel();
        wake.reset();
        _set(KlausState.speaking, textMode && !textModeVoice ? 'A escrever...' : 'A falar...');
        break;

      case 'sentence_start':
        final sentence = data['text']?.toString() ?? '';
        if (sentence.contains('👋')) _armFarewell();
        if (RegExp(r'[kc]laus', caseSensitive: false).hasMatch(sentence)) {
          _selfNameUntil = DateTime.now().add(Duration(milliseconds: 1500 + sentence.length * 90));
        }
        _addChat(false, sentence);
        emotion = _serverEmotion ?? _emo.forSentence(sentence);
        _serverEmotion = null;
        _notify();
        break;

      case 'stop':
        await speaker.drain();
        if (_disposed || state != KlausState.speaking) return;
        _serverEmotion = null;
        if (_sleepAfterReply) {
          await _enterStandby(deep: true);
          return;
        }
        _enterWaiting();
        break;
    }
  }

  // ======================================================================
  // Interrupções, despedida, modo escrito, idiomas
  // ======================================================================

  /// "Klaus" ouvido enquanto ele pensava/falava: cala-se e ouve.
  void _bargeIn() {
    if (DateTime.now().isBefore(_selfNameUntil)) return; // foi ele a dizer o nome
    _sleepAfterReply = false;
    _farewellTimer?.cancel();
    abort();
  }

  Future<void> abort() async {
    _sendJson({'session_id': _sessionId, 'type': 'abort'});
    await speaker.interrupt();
    _segActive = false;
    _segForced = false;
    _enterWaiting();
  }

  void _armFarewell() {
    if (_sleepAfterReply) return;
    _sleepAfterReply = true;
    _farewellTimer?.cancel();
    _farewellTimer = Timer(const Duration(seconds: 15), () {
      if (_sleepAfterReply && state != KlausState.standby) _enterStandby(deep: true);
    });
  }

  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (state == KlausState.speaking) await abort();
    _addChat(true, t);
    emotion = 'thinking';
    _set(KlausState.thinking, 'A pensar...');
    if (!await _ensureConnected()) {
      emotion = 'sad';
      _set(textMode ? KlausState.textIdle : KlausState.waiting, 'Sem ligação ao servidor');
      return;
    }
    _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'detect', 'text': t});
    _armThinkTimeout();
  }

  Future<void> setTextMode(bool on) async {
    if (textMode == on) return;
    textMode = on;
    if (on) {
      textModeVoice = false;
      _cancelTimers();
      _segActive = false;
      await speaker.interrupt();
      await mic.stop();
      emotion = 'happy';
      _set(KlausState.textIdle, 'Modo escrito');
      _ensureConnected();
    } else {
      await speaker.interrupt();
      await mic.start();
      _enterWaiting();
    }
    _notify();
  }

  Future<void> toggleTextVoice() async {
    textModeVoice = !textModeVoice;
    if (!textModeVoice) await speaker.interrupt();
    _notify();
  }

  Future<void> switchLanguage(String code) async {
    final target = langByCode(code);
    if (target.code == lang.code && state != KlausState.error) return;
    _gen++;
    _activating = false;
    _cancelTimers();
    _sendJson({'session_id': _sessionId, 'type': 'abort'});
    _segActive = false;
    await speaker.interrupt();
    await _closeWs();
    lang = target;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('klaus_lang', lang.code);
    emotion = 'thinking';
    _set(KlausState.connecting, 'A mudar para ${lang.name} ${lang.flag}...');
    try {
      identity = await DeviceIdentity.load(lang.prefix);
      final r = await OtaClient(identity!).fetch();
      if (r.needsActivation) {
        activationCode = r.activationCode;
        _set(KlausState.needsActivation, 'Falta ativar o ${lang.agentName}');
        _waitActivation(OtaClient(identity!), r);
        return;
      }
      if (!await _ensureConnected()) {
        _fail('Não consegui ligar ao ${lang.agentName}.');
        return;
      }
      if (textMode) {
        _set(KlausState.textIdle, 'Modo escrito');
        return;
      }
      // Começa logo a aula (ou o regresso) no idioma novo.
      _sendJson({
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'detect',
        'text': lang.code == 'pt'
            ? 'Klaus, voltei para o português!'
            : 'Oi Klaus! Vamos treinar ${lang.name}. Começa a aula.',
      });
      emotion = 'thinking';
      _set(KlausState.thinking, 'A pensar...');
      _armThinkTimeout();
    } catch (e) {
      _fail('Não consegui mudar de idioma: $e');
    }
  }

  // ======================================================================
  // Definições
  // ======================================================================

  Future<void> setWakeSensitivity(String s) async {
    wakeSensitivity = s;
    wake.setSensitivity(s);
    (await SharedPreferences.getInstance()).setString('klaus_wake_sens', s);
    _notify();
  }

  Future<void> setMicSensitivity(String s) async {
    micSensitivity = s;
    mic.setSensitivity(s);
    (await SharedPreferences.getInstance()).setString('klaus_mic_sens', s);
    _notify();
  }

  Future<void> setPauseLength(String s) async {
    pauseLength = s;
    mic.setPause(s);
    (await SharedPreferences.getInstance()).setString('klaus_pause', s);
    _notify();
  }

  Future<void> resetIdentity() async {
    await _closeWs();
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
    _cancelTimers();
    _farewellTimer?.cancel();
    _closeWs();
    mic.dispose();
    wake.dispose();
    speaker.release();
    super.dispose();
  }
}
