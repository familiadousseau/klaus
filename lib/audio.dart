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

/// Microfone: grava PCM 16 kHz e entrega frames Opus de 60 ms.
class MicCapture {
  final AudioRecorder _rec = AudioRecorder();
  SimpleOpusEncoder? _encoder;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _pending = [];
  bool _running = false;

  /// Nível do microfone (0..1) para animar a interface.
  double level = 0;

  // ---- Deteção de voz local (distingue ruído de fundo de alguém a falar) ----
  /// true enquanto parece haver alguém a falar perto do telemóvel.
  bool voiceActive = false;

  /// Chamado quando [voiceActive] muda.
  void Function(bool active)? onVoiceChange;

  /// Sensibilidade: quanto acima do ruído ambiente a voz tem de estar (x vezes).
  double voiceFactor = 3.0;

  double _noiseFloor = 300; // RMS do ruído ambiente (aprendido)
  int _speechFrames = 0;
  int _silenceFrames = 0;

  void _updateVad(Int16List pcm) {
    var sum = 0.0;
    var crossings = 0;
    var prev = 0;
    for (final v in pcm) {
      sum += v * v;
      if ((v >= 0) != (prev >= 0)) crossings++;
      prev = v;
    }
    final rms = pcm.isEmpty ? 0.0 : math.sqrt(sum / pcm.length);
    final zcr = pcm.isEmpty ? 0.0 : crossings / pcm.length;

    // O ruído ambiente desce depressa e sobe devagar (segue os momentos calmos).
    if (rms < _noiseFloor) {
      _noiseFloor = _noiseFloor * 0.8 + rms * 0.2;
    } else {
      _noiseFloor = _noiseFloor * 0.995 + rms * 0.005;
    }
    if (_noiseFloor < 60) _noiseFloor = 60;

    // Voz: bem acima do ruído, com volume mínimo, e "som de fala" (nem chiado nem zumbido).
    final loud = rms > _noiseFloor * voiceFactor && rms > 700;
    final speechLike = zcr > 0.02 && zcr < 0.35;
    if (loud && speechLike) {
      _speechFrames++;
      _silenceFrames = 0;
    } else {
      _silenceFrames++;
      if (_silenceFrames > 2) _speechFrames = 0;
    }

    // Começa após ~180 ms de voz; termina após ~600 ms de silêncio.
    final wasActive = voiceActive;
    if (!voiceActive && _speechFrames >= 3) voiceActive = true;
    if (voiceActive && _silenceFrames >= 10) voiceActive = false;
    if (voiceActive != wasActive) onVoiceChange?.call(voiceActive);
  }

  bool get isRunning => _running;

  static int get _samplesPerFrame =>
      KlausConfig.inputSampleRate * KlausConfig.frameDurationMs ~/ 1000;

  static Future<bool> ensurePermission() async {
    final st = await Permission.microphone.request();
    return st.isGranted;
  }

  Future<void> start(void Function(Uint8List opus) onFrame) async {
    if (_running) return;
    _encoder ??= SimpleOpusEncoder(
      sampleRate: KlausConfig.inputSampleRate,
      channels: KlausConfig.channels,
      application: Application.voip,
    );
    _pending.clear();
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: KlausConfig.inputSampleRate,
      numChannels: KlausConfig.channels,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    ));
    _running = true;
    _sub = stream.listen((chunk) {
      _pending.addAll(chunk);
      final frameBytes = _samplesPerFrame * 2;
      while (_pending.length >= frameBytes) {
        final bytes = Uint8List.fromList(_pending.sublist(0, frameBytes));
        _pending.removeRange(0, frameBytes);
        final pcm = bytes.buffer.asInt16List();
        var peak = 0;
        for (final s in pcm) {
          final a = s < 0 ? -s : s;
          if (a > peak) peak = a;
        }
        level = peak / 32768.0;
        _updateVad(pcm);
        try {
          onFrame(_encoder!.encode(input: pcm));
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
