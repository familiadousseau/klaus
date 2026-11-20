import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'micro_wake.dart';

/// Ouve a palavra "Klaus" no próprio telemóvel, sem internet.
/// Usado enquanto o Klaus dorme, para poupar bateria e dados.
///
/// Primeiro tenta o modelo treinado por nós (microWakeWord, o mesmo da placa ESP32).
/// Se esse falhar, usa o detetor antigo (sherpa-onnx), como até aqui.
class WakeWordDetector {
  static bool _bindingsReady = false;

  MicroWakeWord? _micro;
  bool _microFailed = false;

  /// Que detetor está a ouvir (aparece no menu do app).
  String engine = 'a preparar';

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  bool _running = false;
  bool _busy = false;

  /// Sensibilidade (0.05 = muito sensível … 0.5 = exigente).
  double threshold = 0.2;

  bool get isRunning => _running;

  Future<String> _copyAsset(String dir, String name) async {
    final f = File('$dir/$name');
    final data = await rootBundle.load('assets/kws/$name');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!await f.exists() || await f.length() != bytes.length) {
      await f.writeAsBytes(bytes, flush: true);
    }
    return f.path;
  }

  Future<void> _init() async {
    if (_spotter != null) return;
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/kws');
    if (!await dir.exists()) await dir.create(recursive: true);
    final encoder = await _copyAsset(dir.path, 'encoder.onnx');
    final decoder = await _copyAsset(dir.path, 'decoder.onnx');
    final joiner = await _copyAsset(dir.path, 'joiner.onnx');
    final tokens = await _copyAsset(dir.path, 'tokens.txt');
    final keywords = await _copyAsset(dir.path, 'keywords.txt');

    _spotter = sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
        ),
        tokens: tokens,
        numThreads: 1,
        debug: false,
      ),
      keywordsFile: keywords,
      keywordsThreshold: threshold,
      keywordsScore: 1.5,
    ));
  }

  RecordConfig get _recConfig => const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        noiseSuppress: true,
        echoCancel: true, // não ouvir a própria voz do Klaus
      );

  /// Prepara o modelo novo. Devolve false se não der (fica o antigo).
  Future<bool> _initMicro() async {
    if (_microFailed) return false;
    if (_micro != null && _micro!.failed) {
      _micro!.dispose();
      _micro = null;
      _microFailed = true;
      return false;
    }
    _micro ??= MicroWakeWord();
    if (_micro!.isReady) return true;
    final ok = await _micro!.init();
    if (!ok) {
      _micro = null;
      _microFailed = true;
    }
    return ok;
  }

  /// Começa a ouvir. [onWake] é chamado uma vez quando ouvir "Klaus".
  Future<void> start(void Function() onWake) async {
    if (_running) return;
    if (await _initMicro()) {
      final micro = _micro!;
      engine = 'modelo Klaus (novo)';
      micro.onWake = () {
        if (_running) onWake();
      };
      micro.reset();
      final audio = await _rec.startStream(_recConfig);
      _running = true;
      _sub = audio.listen((chunk) {
        if (_running) micro.feed(chunk);
      });
      return;
    }
    engine = 'sherpa (antigo)';
    await _init();
    _stream?.free();
    _stream = _spotter!.createStream();
    final audio = await _rec.startStream(_recConfig);
    _running = true;
    _sub = audio.listen((chunk) {
      if (!_running || _busy || _stream == null) return;
      _busy = true;
      try {
        final pcm = Uint8List.fromList(chunk).buffer.asInt16List();
        final f = Float32List(pcm.length);
        for (var i = 0; i < pcm.length; i++) {
          f[i] = pcm[i] / 32768.0;
        }
        _stream!.acceptWaveform(samples: f, sampleRate: 16000);
        while (_spotter!.isReady(_stream!)) {
          _spotter!.decode(_stream!);
        }
        final kw = _spotter!.getResult(_stream!).keyword;
        if (kw.isNotEmpty) {
          _spotter!.reset(_stream!);
          onWake();
        }
      } catch (_) {
      } finally {
        _busy = false;
      }
    });
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    _micro?.dispose();
    _micro = null;
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
    _rec.dispose();
  }
}
