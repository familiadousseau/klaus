import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Reconhece a palavra "Klaus" no próprio telemóvel, sem internet.
/// Não tem microfone próprio: recebe os frames do [MicHub] através de [feed].
class WakeWordEngine {
  static bool _bindingsReady = false;

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  List<String> _baseKeywords = [];
  String _sensitivity = 'normal';

  /// Mensagem de erro, se o reconhecimento não conseguiu arrancar.
  String? error;

  bool get ready => _spotter != null && _stream != null;

  Future<String> _copyAsset(String dir, String name) async {
    final f = File('$dir/$name');
    final data = await rootBundle.load('assets/kws/$name');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!await f.exists() || await f.length() != bytes.length) {
      await f.writeAsBytes(bytes, flush: true);
    }
    return f.path;
  }

  /// Prepara o modelo (uma vez). Em caso de falha, guarda a razão em [error].
  Future<void> init() async {
    if (_spotter != null) return;
    try {
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
      final keywordsPath = await _copyAsset(dir.path, 'keywords.txt');

      _baseKeywords = File(keywordsPath)
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) => l.split('@').first.split(RegExp(r'\s[:#]')).first.trim())
          .toList();

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
        keywordsFile: keywordsPath,
        keywordsThreshold: 0.15,
        keywordsScore: 2.0,
      ));
      _newStream();
      error = null;
    } catch (e) {
      error = 'Reconhecimento de "Klaus" indisponível: $e';
      _spotter = null;
      _stream = null;
    }
  }

  /// Sensibilidade: 'alta' (acorda mais fácil), 'normal' ou 'baixa' (menos falsos alarmes).
  void setSensitivity(String s) {
    _sensitivity = s;
    if (_spotter != null) _newStream();
  }

  void _newStream() {
    _stream?.free();
    _stream = null;
    final (score, thr) = switch (_sensitivity) {
      'alta' => (2.5, 0.08),
      'baixa' => (1.5, 0.25),
      _ => (2.0, 0.15),
    };
    // Cada palavra leva o seu reforço (:) e limiar (#). Separadas por "/".
    final kw = _baseKeywords.map((t) => '$t :$score #$thr @KLAUS').join('/');
    try {
      _stream = kw.isEmpty ? _spotter!.createStream() : _spotter!.createStream(keywords: kw);
    } catch (_) {
      _stream = _spotter!.createStream(); // usa o ficheiro tal como está
    }
  }

  /// Recebe 60 ms de áudio. Devolve true se ouviu "Klaus".
  bool feed(Int16List pcm) {
    final st = _stream;
    final sp = _spotter;
    if (st == null || sp == null) return false;
    final f = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      f[i] = pcm[i] / 32768.0;
    }
    st.acceptWaveform(samples: f, sampleRate: 16000);
    while (sp.isReady(st)) {
      sp.decode(st);
    }
    if (sp.getResult(st).keyword.isNotEmpty) {
      sp.reset(st);
      return true;
    }
    return false;
  }

  /// Limpa o que estava a meio (ao mudar de estado).
  void reset() {
    final st = _stream;
    final sp = _spotter;
    if (st != null && sp != null) {
      try {
        sp.reset(st);
      } catch (_) {}
    }
  }

  void dispose() {
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}
