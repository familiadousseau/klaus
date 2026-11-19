import 'dart:async';
import 'dart:collection';
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
