import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_player/flutter_pcm_player.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'config.dart';

/// Microfone único do app: um só gravador, sempre ligado enquanto o Klaus está ativo.
/// Entrega frames PCM de 60 ms (960 amostras a 16 kHz) e faz a deteção de voz local.
/// Assim não se perde áudio ao passar de "à espera de Klaus" para "a conversar".
class MicHub {
  final AudioRecorder _rec = AudioRecorder();
  SimpleOpusEncoder? _encoder;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _pending = [];
  bool _running = false;

  /// Recebe cada frame PCM de 60 ms.
  void Function(Int16List pcm)? onFrame;

  /// Chamado quando a deteção de voz muda (true = alguém começou a falar).
  void Function(bool active)? onVoiceChange;

  /// Nível do microfone (0..1) para animar a interface.
  double level = 0;

  bool get isRunning => _running;

  // ---- Deteção de voz local ----
  bool voiceActive = false;

  /// Quanto acima do ruído ambiente a voz tem de estar para COMEÇAR (x vezes).
  double startFactor = 2.0;

  /// Volume mínimo (RMS) para contar como voz.
  double minRms = 300;

  /// Silêncio (em frames de 60 ms) para considerar que a pessoa acabou de falar.
  int endSilenceFrames = 18; // ~1,1 s

  double _noiseFloor = 250;
  double _speechLevel = 0; // volume médio da sua voz na frase atual
  int _speechFrames = 0;
  int _silenceFrames = 0;

  /// Sensibilidade do microfone: 'alta', 'normal' ou 'baixa'.
  void setSensitivity(String s) {
    switch (s) {
      case 'alta':
        startFactor = 1.6;
        minRms = 180;
        break;
      case 'baixa':
        startFactor = 2.8;
        minRms = 500;
        break;
      default:
        startFactor = 2.0;
        minRms = 300;
    }
  }

  /// Pausa antes de responder: 'curta', 'normal' ou 'longa'.
  void setPause(String s) {
    switch (s) {
      case 'curta':
        endSilenceFrames = 12; // ~0,7 s
        break;
      case 'longa':
        endSilenceFrames = 28; // ~1,7 s
        break;
      default:
        endSilenceFrames = 18; // ~1,1 s
    }
  }

  void _updateVad(Int16List pcm) {
    var sum = 0.0;
    var crossings = 0;
    var prev = 0;
    var peak = 0;
    for (final v in pcm) {
      sum += v * v;
      if ((v >= 0) != (prev >= 0)) crossings++;
      prev = v;
      final a = v < 0 ? -v : v;
      if (a > peak) peak = a;
    }
    level = peak / 32768.0;
    final rms = pcm.isEmpty ? 0.0 : math.sqrt(sum / pcm.length);
    final zcr = pcm.isEmpty ? 0.0 : crossings / pcm.length;

    // O ruído ambiente só é aprendido quando NINGUÉM está a falar
    // (antes subia durante a fala e o Klaus ficava surdo).
    if (!voiceActive) {
      if (rms < _noiseFloor) {
        _noiseFloor = _noiseFloor * 0.85 + rms * 0.15;
      } else {
        _noiseFloor = _noiseFloor * 0.99 + rms * 0.01;
      }
      if (_noiseFloor < 50) _noiseFloor = 50;
    }

    final speechLike = zcr > 0.01 && zcr < 0.45;
    bool isSpeech;
    if (!voiceActive) {
      // Para COMEÇAR: bem acima do ruído ambiente e com volume mínimo.
      isSpeech = rms > _noiseFloor * startFactor && rms > minRms && speechLike;
      if (isSpeech) _speechLevel = rms;
    } else {
      // Para CONTINUAR: o som tem de estar perto do volume da SUA voz.
      // Quando cai para muito abaixo (ex.: só ruído de fundo), conta como silêncio.
      final keep = math.max(_noiseFloor * startFactor * 0.8, _speechLevel * 0.22);
      isSpeech = rms > keep && rms > minRms * 0.6;
      if (isSpeech) _speechLevel = _speechLevel * 0.9 + rms * 0.1;
    }

    if (isSpeech) {
      _speechFrames++;
      _silenceFrames = 0;
    } else {
      _silenceFrames++;
      if (_silenceFrames > 2) _speechFrames = 0;
    }

    final was = voiceActive;
    if (!voiceActive && _speechFrames >= 3) voiceActive = true; // ~180 ms de voz
    if (voiceActive && _silenceFrames >= endSilenceFrames) voiceActive = false;
    if (voiceActive != was) onVoiceChange?.call(voiceActive);
  }

  static Future<bool> ensurePermission() async {
    final st = await Permission.microphone.request();
    return st.isGranted;
  }

  static int get _samplesPerFrame =>
      KlausConfig.inputSampleRate * KlausConfig.frameDurationMs ~/ 1000;

  /// Codifica um frame PCM em Opus (para enviar ao servidor).
  Uint8List encode(Int16List pcm) {
    _encoder ??= SimpleOpusEncoder(
      sampleRate: KlausConfig.inputSampleRate,
      channels: KlausConfig.channels,
      application: Application.voip,
    );
    return _encoder!.encode(input: pcm);
  }

  Future<void> start() async {
    if (_running) return;
    _pending.clear();
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: KlausConfig.inputSampleRate,
      numChannels: KlausConfig.channels,
      echoCancel: true, // para ouvir "Klaus" mesmo enquanto ele fala
      noiseSuppress: true,
      autoGain: false, // o ganho automático aumentava o ruído depois de parar de falar
    ));
    _running = true;
    _sub = stream.listen((chunk) {
      _pending.addAll(chunk);
      final frameBytes = _samplesPerFrame * 2;
      while (_pending.length >= frameBytes) {
        final bytes = Uint8List.fromList(_pending.sublist(0, frameBytes));
        _pending.removeRange(0, frameBytes);
        final pcm = bytes.buffer.asInt16List();
        _updateVad(pcm);
        try {
          onFrame?.call(pcm);
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    level = 0;
    _speechFrames = 0;
    _silenceFrames = 0;
    if (voiceActive) {
      voiceActive = false;
      onVoiceChange?.call(false);
    }
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    _pending.clear();
  }

  Future<void> dispose() async {
    await stop();
    _encoder?.destroy();
    _rec.dispose();
  }
}

/// Altifalante: descodifica Opus e toca PCM com um pequeno buffer controlado em Dart,
/// para conseguir interromper na hora e saber quando a fala terminou.
class SpeakerPlayback {
  FlutterPcmPlayer? _player;
  SimpleOpusDecoder? _decoder;
  int _sampleRate = 24000;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  Timer? _pump;
  final Stopwatch _clock = Stopwatch();
  double _fedMs = 0; // milissegundos de áudio já entregues ao AudioTrack
  bool _ready = false;

  /// Nível do som (0..1) para a boca "mexer".
  double level = 0;

  static Future<void> configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ));
  }

  Future<void> setup(int sampleRate) async {
    if (_ready && sampleRate == _sampleRate) return;
    await release();
    _sampleRate = sampleRate;
    _decoder = SimpleOpusDecoder(sampleRate: _sampleRate, channels: 1);
    _player = FlutterPcmPlayer();
    await _player!.initialize(nChannels: 1, sampleRate: _sampleRate);
    await _player!.play();
    _ready = true;
  }

  /// Recebe um pacote Opus vindo do servidor.
  void addOpus(Uint8List opus) {
    if (!_ready || _decoder == null) return;
    try {
      final pcm = _decoder!.decode(input: opus);
      _queue.add(Uint8List.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes));
    } catch (_) {}
    _pump ??= Timer.periodic(const Duration(milliseconds: 20), (_) => _tick());
  }

  void _tick() {
    if (!_ready || _player == null) return;
    if (!_clock.isRunning) {
      _clock
        ..reset()
        ..start();
      _fedMs = 0;
    }
    // Se o buffer esvaziou, recomeça a contagem.
    if (_fedMs < _clock.elapsedMilliseconds) {
      _clock
        ..reset()
        ..start();
      _fedMs = 0;
    }
    // Mantém ~250 ms de áudio adiantado no AudioTrack.
    while (_queue.isNotEmpty && _fedMs - _clock.elapsedMilliseconds < 250) {
      final chunk = _queue.removeFirst();
      final ms = chunk.lengthInBytes / 2 / _sampleRate * 1000;
      _fedMs += ms;
      var peak = 0;
      final s16 = chunk.buffer.asInt16List(chunk.offsetInBytes, chunk.lengthInBytes ~/ 2);
      for (var i = 0; i < s16.length; i += 8) {
        final a = s16[i] < 0 ? -s16[i] : s16[i];
        if (a > peak) peak = a;
      }
      level = peak / 32768.0;
      _player!.feed(chunk);
    }
    if (_queue.isEmpty && _fedMs <= _clock.elapsedMilliseconds) {
      level = 0;
    }
  }

  /// true enquanto ainda há som por tocar.
  bool get isBusy =>
      _queue.isNotEmpty || (_clock.isRunning && _fedMs > _clock.elapsedMilliseconds);

  /// Espera até acabar de tocar o que está em fila.
  Future<void> drain() async {
    var guard = 0;
    while (isBusy && guard < 600) {
      await Future.delayed(const Duration(milliseconds: 50));
      guard++;
    }
    await Future.delayed(const Duration(milliseconds: 150));
  }

  /// Interrompe já: descarta a fila e reinicia o AudioTrack.
  Future<void> interrupt() async {
    _queue.clear();
    level = 0;
    final rate = _sampleRate;
    _ready = false;
    await release();
    await setup(rate);
  }

  Future<void> release() async {
    _pump?.cancel();
    _pump = null;
    _queue.clear();
    _clock
      ..stop()
      ..reset();
    _fedMs = 0;
    try {
      await _player?.release();
    } catch (_) {}
    _player = null;
    _decoder?.destroy();
    _decoder = null;
    _ready = false;
  }
}
