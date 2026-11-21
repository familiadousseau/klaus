import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import 'audio.dart';
import 'config.dart';
import 'emotion_engine.dart';
import 'identity.dart';
import 'languages.dart';
import 'ota.dart';
import 'radio.dart';
import 'wake_word.dart';

enum KlausState { starting, needsActivation, connecting, idle, listening, thinking, speaking, error }

class ChatLine {
  final bool fromUser;
  final String text;
  final DateTime at = DateTime.now();
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

  /// Rádio pela internet (a IA chama as ferramentas self.radio.*).
  final KlausRadio radio = KlausRadio();

  KlausClient() {
    radio.addListener(notifyListeners);
  }
  bool sleeping = false;
  bool _sleepAfterReply = false;
  String? _pendingSwitch; // idioma pedido pelo Klaus (bandeira na resposta)
  bool _translatorOn = false; // modo tradutor bilíngue ligado
  DateTime _selfNameUntil = DateTime(2000); // enquanto ele próprio diz "Klaus"
  bool _startAsleep = true; // ao abrir o app, espera ouvir "Klaus"
  Timer? _farewellTimer;
  bool drowsy = false;
  DateTime _lastActivity = DateTime.now();
  Timer? _sleepTimer;
  static const drowsyAfter = Duration(seconds: 40);
  static const sleepAfter = Duration(seconds: 60);
  String? _serverEmotion;
  Timer? _retry;

  // ---- Ordens que o próprio app manda ao agente (texto "detect") ----
  // O servidor devolve esse texto como se a pessoa o tivesse dito (stt). Não pode ser lido
  // como comando: a ordem do modo tradutor tem "modo tradutor" + "italiano" e voltaria a
  // ligá-lo, religando o agente sem parar.
  String? _kickoff;
  DateTime _kickoffAt = DateTime(2000);
  String? _typed; // texto escrito no modo escrito (já está no histórico)

  // ---- Fala ----
  int _ttsTurn = 0; // muda a cada fala nova, para o fim de uma não cortar a seguinte

  /// Vezes em que o som faltou a meio de uma fala (aparece no menu).
  int get audioGaps => speaker.gaps;

  // ---- Contexto entre sonos ----
  static const _recapMaxAge = Duration(hours: 4);
  String? _recap; // resumo da conversa antes de adormecer
  DateTime _recapAt = DateTime(2000);

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
          markActivity(); // o tempo a pensar não conta como silêncio
          _startListening(auto: true);
        }
      });
    }
    if (!_disposed) notifyListeners();
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9à-ÿ]+'), '');

  /// Manda ao agente um texto como se fosse dito (ordem do app, cumprimento, aula...).
  void _sendDetect(String text, {bool own = true}) {
    if (own) {
      _kickoff = text;
      _kickoffAt = DateTime.now();
    }
    _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'detect', 'text': text});
  }

  /// O texto reconhecido é só o eco de uma ordem do app?
  bool _isKickoffEcho(String said) {
    final k = _kickoff;
    if (k == null || DateTime.now().difference(_kickoffAt) > const Duration(seconds: 30)) return false;
    final a = _norm(said), b = _norm(k);
    if (a.isEmpty || b.isEmpty) return false;
    final n = math.min(40, math.min(a.length, b.length));
    final echo = a == b || (n >= 12 && a.substring(0, n) == b.substring(0, n));
    if (echo) _kickoff = null;
    return echo;
  }

  static final _emojiRe = RegExp(
      r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]',
      unicode: true);

  /// Resumo das últimas falas (das últimas horas), para o Klaus não perder o fio ao acordar.
  String? _buildRecap() {
    final since = DateTime.now().subtract(_recapMaxAge);
    final lines = <String>[];
    var total = 0;
    for (final l in chat.reversed) {
      if (l.at.isBefore(since)) break;
      var s = l.text.replaceAll(_emojiRe, '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (s.length < 2) continue;
      if (s.length > 240) s = '${s.substring(0, 240)}…';
      final line = '${l.fromUser ? 'Eu' : 'Você'}: $s';
      if (lines.length >= 16 || total + line.length > 1400) break;
      lines.insert(0, line);
      total += line.length;
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  Future<void> _saveRecap() async {
    final r = _buildRecap();
    if (r == null) return;
    _recap = r;
    _recapAt = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('klaus_recap', r);
      await prefs.setInt('klaus_recap_at', _recapAt.millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _loadRecap() async {
    if (_recap != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _recap = prefs.getString('klaus_recap');
      _recapAt = DateTime.fromMillisecondsSinceEpoch(prefs.getInt('klaus_recap_at') ?? 0);
    } catch (_) {}
  }

  /// Texto mandado ao acordar: o nome e, se houve conversa há pouco, o fio da meada.
  String _wakeText() {
    final r = _recap;
    if (r == null || DateTime.now().difference(_recapAt) > _recapMaxAge) return 'Klaus';
    return 'Klaus! (Você acabou de acordar. Antes de dormir, a nossa conversa foi esta:\n$r\n'
        'É a mesma conversa: se eu voltar a esse assunto ou perguntar algo que foi dito, '
        'responda com base nisto. Agora só me cumprimente com uma frase curta, '
        'sem repetir nem comentar este resumo.)';
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
      await _loadRecap();
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
      'features': {'mcp': true}, // ferramentas do aparelho (rádio)
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
        // Eco de uma ordem do próprio app: não é a pessoa a falar, não é comando.
        if (_isKickoffEcho(said)) {
          _set(KlausState.thinking, 'A pensar...');
          emotion = 'thinking';
          notifyListeners();
          break;
        }
        if (said.trim().length > 1) markActivity(); // frase reconhecida = conversa real
        // Texto escrito: já está no histórico (o servidor só o devolve).
        if (_typed != null && _norm(said) == _norm(_typed!)) {
          _typed = null;
        } else {
          _addChat(true, said);
        }
        // MODO TRADUÇÃO: o app reconhece o comando e manda ele próprio a ordem completa ao agente.
        final cmd = detectTranslatorCommand(said);
        final stopTranslator = cmd?.$1 == 'stop' || detectTranslatorStop(said);
        if (stopTranslator) {
          _translatorOn = false;
          await switchLanguage(lang.code,
              force: true,
              kickoff: 'Klaus, PARAR TRADUÇÃO: sai do modo tradutor e volta à conversa normal. '
                  'Confirma numa frase curta.');
          return;
        }
        // No modo tradutor as despedidas são para traduzir, não para adormecer
        // (só "Klaus, descansar" e outras ordens curtas com o nome contam).
        if ((!_translatorOn || isShortKlausCommand(said)) && detectFarewell(said)) _armFarewell();
        var translate = cmd?.$1 == 'start' ? (cmd!.$2 ?? lang.code) : detectTranslatorRequest(said);
        if (translate == 'pt') translate = lang.code; // "traduz para português" num agente estrangeiro
        if (translate != null && translate != 'pt') {
          // Muda para o Klaus dessa língua (voz nativa) ou, se já é este, reinicia-o já em modo tradutor.
          await switchLanguage(translate, translator: true, force: true);
          return;
        }
        // Durante o modo tradutor só o comando curto ("Klaus, português!") troca de agente,
        // para a fala da outra pessoa ("parliamo italiano") não mudar nada.
        final wanted = translate != null
            ? null
            : _translatorOn
                ? detectShortSwitch(said)
                : detectLanguageSwitch(said);
        if (wanted != null && wanted != lang.code) {
          await switchLanguage(wanted, lesson: detectLessonRequest(said));
          return;
        }
        _set(KlausState.thinking, 'A pensar...');
        emotion = 'thinking';
        notifyListeners();
        break;
      case 'llm':
        // 👋 = a IA percebeu que é uma despedida (combinado na personalidade).
        if ((data['text']?.toString() ?? '').contains('👋')) _armFarewell();
        _checkFlag(data['text']?.toString() ?? '');
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
        final payload = data['payload'];
        if (payload is Map) await _handleMcp(Map<String, dynamic>.from(payload));
        break;
    }
  }

  Future<void> _onTts(Map<String, dynamic> data) async {
    switch (data['state']) {
      case 'start':
        _ttsTurn++;
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
        _checkFlag(sentence);
        // Se a frase que ele vai dizer tem o próprio nome, não se interrompe sozinho.
        if (RegExp(r'[kc]laus', caseSensitive: false).hasMatch(sentence)) {
          final ms = 1500 + sentence.length * 90;
          _selfNameUntil = DateTime.now().add(Duration(milliseconds: ms));
        }
        markActivity(); // enquanto fala, o tempo de sono não corre
        _addChat(false, sentence);
        // Carinha frase a frase: o que ele diz manda; a emoção do servidor só
        // vale para a primeira frase da resposta.
        emotion = _serverEmotion ?? _emo.forSentence(sentence);
        _serverEmotion = null;
        notifyListeners();
        break;
      case 'stop':
        final turn = _ttsTurn;
        speaker.endOfStream();
        await speaker.drain();
        // Enquanto acabava de tocar, começou outra fala (p. ex. depois de pôr a rádio):
        // não a corta nem liga o microfone por cima dela.
        if (turn != _ttsTurn) return;
        // O tempo sem resposta conta a partir de AGORA (fim da fala), não do início:
        // depois de uma resposta longa ele espera a sua resposta antes de adormecer.
        markActivity();
        await wake.stop();
        if (_disposed) return;
        _serverEmotion = null;
        emotion = 'neutral';
        if (_pendingSwitch != null && !_sleepAfterReply) {
          final code = _pendingSwitch!;
          _pendingSwitch = null;
          await switchLanguage(code);
          return;
        }
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
    _typed = t;
    _sendDetect(t, own: false);
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
  void _checkFlag(String text) {
    final code = detectFlagSwitch(text);
    if (code != null && code != lang.code) _pendingSwitch = code;
  }

  void _armFarewell() {
    if (_sleepAfterReply || sleeping) return;
    _sleepAfterReply = true;
    _farewellTimer?.cancel();
    _farewellTimer = Timer(const Duration(seconds: 15), () {
      // Ainda a falar: quando acabar, o fim da fala põe-no a dormir.
      if (_sleepAfterReply && !sleeping && state != KlausState.speaking) goToSleep();
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
    unawaited(radio.duck(false)); // a dormir: rádio no volume normal
    _sleepAfterReply = false;
    _farewellTimer?.cancel();
    drowsy = false;
    if (mic.isRunning) {
      _sendJson({'session_id': _sessionId, 'type': 'listen', 'state': 'stop'});
      await mic.stop();
    }
    await speaker.release(); // a dormir não precisa do altifalante (volta ao acordar)
    await wake.stop();
    await _closeWs();
    unawaited(_saveRecap());
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
    unawaited(radio.duck(true)); // a conversar: rádio baixinho
    await wake.stop();
    markActivity();
    emotion = 'surprised';
    _set(KlausState.connecting, 'A acordar...');
    await connect();
    if (_ws != null && !textMode) {
      // Igual a um aparelho XiaoZhi que ouviu a palavra de ativação: o servidor cumprimenta.
      // Se houve conversa há pouco, vai junto o resumo, para continuar o mesmo assunto.
      _sendDetect(_wakeText());
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

  static String _ptName(String code) =>
      const {'pt': 'português', 'en': 'inglês', 'it': 'italiano', 'de': 'alemão'}[code] ?? code;

  /// Troca para o Klaus de outro idioma (outro agente, com voz nativa).
  /// Ordem clara do modo tradutor, enviada pelo app ao agente da língua [code].
  static String _translatorInstruction(String code) {
    final l = _ptName(code);
    return 'Klaus, liga o MODO TRADUTOR. Vou usar-te para falar com outra pessoa. Regras: '
        '1) Tudo o que eu disser, em qualquer língua que não seja $l, diz só a tradução em $l, '
        'para a outra pessoa entender. '
        '2) O que a outra pessoa disser em $l, diz só a tradução em português, para mim. '
        'Traduz na mesma pessoa, como se fosses eu. Nunca respondas, nunca comentes, nunca acrescentes nada: '
        'se for uma pergunta, traduz a pergunta. Fica assim até eu dizer "parar tradução". '
        'Agora confirma só com uma frase curta em $l.';
  }

  bool get translatorOn => _translatorOn;

  Future<void> switchLanguage(String code,
      {bool translator = false, bool lesson = false, String? kickoff, bool force = false}) async {
    _pendingSwitch = null;
    final target = langByCode(code);
    if (target.code == lang.code && state != KlausState.error && !force) return;
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
    _translatorOn = translator;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('klaus_lang', lang.code);
    emotion = 'thinking';
    _set(KlausState.connecting,
        translator ? 'Modo tradutor: ${lang.name} ${lang.flag}...' : 'A mudar para ${lang.name} ${lang.flag}...');
    try {
      identity = await DeviceIdentity.load(lang.prefix);
      _startAsleep = false;
      await _runOta();
      if (_ws != null && !textMode) {
        // Começa logo a aula (ou o regresso) no idioma novo.
        _sendDetect(kickoff != null
            ? kickoff
            : translator
                ? _translatorInstruction(lang.code)
                : lang.code == 'pt'
                    ? 'Klaus, voltei para o português!'
                    // Só pede aula se a pessoa pediu treino; senão é conversa normal.
                    : lesson
                        ? 'Oi Klaus! Vamos treinar línguas. Começa a aula.'
                        : 'Oi Klaus! Tudo bem?');
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

  // ---------------------------------------------------------------------------
  // Ferramentas do aparelho (MCP, como nos aparelhos XiaoZhi oficiais).
  // O servidor pergunta que ferramentas há (tools/list) e a IA chama-as (tools/call).
  // ---------------------------------------------------------------------------

  static const List<Map<String, dynamic>> _mcpTools = [
    {
      'name': 'self.radio.play',
      'description': 'Play an internet radio station on the user\'s phone. Use it when the user asks '
          'for the radio, for a station by name (e.g. "Rádio Comercial", "Antena 1", "BBC Radio 1") '
          'or for radio of a music style or country. Afterwards say in a few words what is playing.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Station name as the user said it, e.g. "Rádio Comercial". Empty if only a style was asked.',
          },
          'style': {
            'type': 'string',
            'description': 'Music style or topic in English, e.g. "jazz", "rock", "pop", "classical", "news". Optional.',
          },
          'country': {
            'type': 'string',
            'description': 'Two-letter country code, e.g. "PT", "BR", "IT", "DE", "GB". Optional.',
          },
        },
      },
    },
    {
      'name': 'self.radio.stop',
      'description': 'Stop the radio that is playing on the user\'s phone.',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'self.radio.set_volume',
      'description': 'Set the radio volume on the user\'s phone, from 0 to 100.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'volume': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        },
        'required': ['volume'],
      },
    },
  ];

  Future<void> _handleMcp(Map<String, dynamic> req) async {
    final id = req['id'];
    final method = req['method']?.toString();
    if (method == null || id == null) return; // notificação: não se responde
    final params = req['params'] is Map ? Map<String, dynamic>.from(req['params'] as Map) : <String, dynamic>{};
    final modern = params['_meta'] is Map &&
        (params['_meta'] as Map).containsKey('io.modelcontextprotocol/protocolVersion');

    void reply(Map<String, dynamic> result) {
      if (modern) result = {'resultType': 'complete', ...result};
      _sendJson({
        'session_id': _sessionId,
        'type': 'mcp',
        'payload': {'jsonrpc': '2.0', 'id': id, 'result': result},
      });
    }

    void error(int code, String message) {
      _sendJson({
        'session_id': _sessionId,
        'type': 'mcp',
        'payload': {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        },
      });
    }

    switch (method) {
      case 'initialize':
        reply({
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'klaus-android', 'version': '${KlausConfig.buildNumber}'},
        });
        break;
      case 'tools/list':
        reply({
          'tools': _mcpTools,
          if (modern) 'ttlMs': 60000,
          if (modern) 'cacheScope': 'private',
        });
        break;
      case 'tools/call':
        final name = params['name']?.toString() ?? '';
        final args = params['arguments'] is Map
            ? Map<String, dynamic>.from(params['arguments'] as Map)
            : <String, dynamic>{};
        var text = '';
        var failed = false;
        try {
          switch (name) {
            case 'self.radio.play':
              text = await radio.play(
                name: args['name']?.toString(),
                style: args['style']?.toString(),
                country: args['country']?.toString(),
              );
              failed = !radio.isPlaying;
              if (radio.isPlaying) {
                await radio.duck(!sleeping);
                // Depois de dizer o que está a tocar, o Klaus adormece e a rádio fica no volume normal.
                _armFarewell();
              }
              break;
            case 'self.radio.stop':
              await radio.stop();
              text = 'Rádio parada.';
              break;
            case 'self.radio.set_volume':
              final v = args['volume'];
              text = await radio.setVolume(v is num ? v.round() : int.tryParse('$v') ?? 50);
              break;
            default:
              error(-32602, 'Unknown tool: $name');
              return;
          }
        } catch (e) {
          text = 'Erro: $e';
          failed = true;
        }
        reply({
          'content': [
            {'type': 'text', 'text': text}
          ],
          'isError': failed,
        });
        break;
      default:
        // Inclui "server/discover": somos um aparelho da versão antiga do protocolo.
        error(-32601, 'Method not implemented: $method');
    }
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
    radio.removeListener(notifyListeners);
    radio.dispose();
    _closeWs();
    mic.dispose();
    speaker.release();
    super.dispose();
  }
}
