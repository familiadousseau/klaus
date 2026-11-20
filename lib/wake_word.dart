import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Ouve a palavra "Klaus" no próprio telemóvel, sem internet.
/// Usado enquanto o Klaus dorme, para poupar bateria e dados.
class WakeWordDetector {
  static bool _bindingsReady = false;

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

  /// Começa a ouvir. [onWake] é chamado uma vez quando ouvir "Klaus".
  Future<void> start(void Function() onWake) async {
    if (_running) return;
    await _init();
    _stream?.free();
    _stream = _spotter!.createStream();
    final audio = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      noiseSuppress: true,
      echoCancel: true, // não ouvir a própria voz do Klaus
    ));
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
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
    _rec.dispose();
  }
}
