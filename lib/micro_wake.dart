import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Detetor da palavra "Klaus" com o modelo treinado por nós (microWakeWord).
///
/// O mesmo modelo vai depois para a placa ESP32. Tudo corre numa thread à parte
/// (isolate), para não pesar no app:
///   áudio 16 kHz → preparação nativa (libklaus_wake.so, igual ao treino)
///   → 40 valores a cada 10 ms → modelo a cada 30 ms → média das últimas 5
///   probabilidades acima do limiar = "Klaus!".
class MicroWakeWord {
  static const modelAsset = 'assets/wakeword/klaus.tflite';

  /// Limiar de deteção (0..1). Mais alto = mais exigente.
  final double cutoff;
  MicroWakeWord({this.cutoff = 0.93});

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  void Function()? onWake;
  bool get isReady => _toWorker != null;

  /// Deu erro depois de arrancar: o app volta ao detetor antigo.
  bool failed = false;

  /// Arranca a thread e carrega o modelo. Devolve false se algo falhar
  /// (aí o app usa o detetor antigo).
  Future<bool> init() async {
    if (_toWorker != null) return true;
    try {
      // O modelo vai para um ficheiro: o TFLite lê-o de lá sem gastar memória a mais.
      final data = await rootBundle.load(modelAsset);
      final model = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/klaus_wake.tflite');
      await file.writeAsBytes(model, flush: true);
      final rp = ReceivePort();
      _fromWorker = rp;
      final ready = Completer<bool>();
      rp.listen((msg) {
        if (msg is SendPort) {
          _toWorker = msg;
          if (!ready.isCompleted) ready.complete(true);
        } else if (msg == 'wake') {
          onWake?.call();
        } else if (msg is String && msg.startsWith('error:')) {
          if (!ready.isCompleted) {
            ready.complete(false);
          } else {
            failed = true;
          }
        }
      });
      _isolate = await Isolate.spawn(
        _workerMain,
        [rp.sendPort, file.path, cutoff],
        debugName: 'klaus-wake',
      );
      final ok = await ready.future.timeout(const Duration(seconds: 8), onTimeout: () => false);
      if (!ok) dispose();
      return ok;
    } catch (_) {
      dispose();
      return false;
    }
  }

  /// Recomeça do zero (antes de cada escuta).
  void reset() => _toWorker?.send('reset');

  /// Áudio PCM 16 bits, mono, 16 kHz.
  void feed(Uint8List pcm) {
    final w = _toWorker;
    if (w == null || pcm.isEmpty) return;
    w.send(TransferableTypedData.fromList([pcm]));
  }

  void dispose() {
    _toWorker?.send('close');
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
  }
}

// ---------------------------------------------------------------------------
// Thread do detetor
// ---------------------------------------------------------------------------

typedef _CreateC = Pointer<Void> Function();
typedef _ResetC = Void Function(Pointer<Void>);
typedef _ResetD = void Function(Pointer<Void>);
typedef _ProcessC = Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint16>, Int32);
typedef _ProcessD = int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint16>, int);

class _Worker {
  static const features = 40;
  static const stride = 3; // o modelo recebe 3 conjuntos de 40 valores (30 ms) de cada vez
  static const window = 5; // média das últimas 5 probabilidades (como no ESPHome)
  static const warmup = 30; // ignora ~1 s depois de (re)começar
  static const maxSamples = 16000;
  static const maxFrames = 120;

  final String modelPath;
  final double cutoff;
  final InterpreterOptions options = InterpreterOptions()..threads = 1;
  late final Pointer<Void> fe;
  late final _ResetD feReset;
  late final _ProcessD feProcess;
  late Interpreter interp;
  late Tensor inT;
  late Tensor outT;
  late double inScale;
  late int inZp;
  late double outScale;
  late int outZp;
  late bool outSigned;

  final Pointer<Int16> pcm = calloc<Int16>(maxSamples);
  final Pointer<Uint16> feats = calloc<Uint16>(maxFrames * features);
  final Uint8List input = Uint8List(stride * features);
  int pendingFrames = 0;
  final List<double> recent = [];
  int skip = warmup;

  _Worker(this.modelPath, this.cutoff) {
    final lib = DynamicLibrary.open('libklaus_wake.so');
    fe = lib.lookupFunction<_CreateC, _CreateC>('kw_create')();
    if (fe == nullptr) throw StateError('frontend');
    feReset = lib.lookupFunction<_ResetC, _ResetD>('kw_reset');
    feProcess = lib.lookupFunction<_ProcessC, _ProcessD>('kw_process');
    _loadModel();
  }

  void _loadModel() {
    interp = Interpreter.fromFile(File(modelPath), options: options);
    interp.allocateTensors();
    inT = interp.getInputTensor(0);
    outT = interp.getOutputTensor(0);
    final shape = inT.shape;
    if (shape.length != 3 || shape[1] != stride || shape[2] != features) {
      throw StateError('modelo inesperado: $shape');
    }
    inScale = inT.params.scale;
    inZp = inT.params.zeroPoint;
    if (inScale <= 0) {
      // Valores do microWakeWord (0..26 → -128..127).
      inScale = 26.0 / 255.0;
      inZp = -128;
    }
    outScale = outT.params.scale > 0 ? outT.params.scale : 1 / 256.0;
    outZp = outT.params.zeroPoint;
    outSigned = outT.type == TensorType.int8;
  }

  void reset() {
    feReset(fe);
    interp.close();
    _loadModel(); // limpa a memória interna do modelo
    pendingFrames = 0;
    recent.clear();
    skip = warmup;
  }

  /// Devolve true se ouviu "Klaus".
  bool process(Uint8List bytes) {
    final samples = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    var detected = false;
    var pos = 0;
    while (pos < samples.length) {
      final n = math.min(maxSamples, samples.length - pos);
      pcm.asTypedList(n).setRange(0, n, samples, pos);
      pos += n;
      final frames = feProcess(fe, pcm, n, feats, maxFrames);
      final f = feats.asTypedList(frames * features);
      for (var k = 0; k < frames; k++) {
        // 40 valores do treino: uint16 × 0,0390625 → int8 com a escala do modelo.
        final base = pendingFrames * features;
        for (var i = 0; i < features; i++) {
          final v = f[k * features + i] * 0.0390625;
          var q = (v / inScale).round() + inZp;
          if (q < -128) q = -128;
          if (q > 127) q = 127;
          input[base + i] = q & 0xff;
        }
        pendingFrames++;
        if (pendingFrames == stride) {
          pendingFrames = 0;
          if (_infer()) detected = true;
        }
      }
    }
    return detected;
  }

  bool _infer() {
    inT.data = input;
    interp.invoke();
    var raw = outT.data[0];
    if (outSigned && raw > 127) raw -= 256;
    final p = (raw - outZp) * outScale;
    if (skip > 0) {
      skip--;
      return false;
    }
    recent.add(p);
    if (recent.length > window) recent.removeAt(0);
    if (recent.length < window) return false;
    final mean = recent.reduce((a, b) => a + b) / window;
    if (mean > cutoff) {
      recent.clear();
      skip = warmup; // não dispara duas vezes seguidas
      return true;
    }
    return false;
  }

  void close() {
    try {
      interp.close();
      options.delete();
    } catch (_) {}
    calloc.free(pcm);
    calloc.free(feats);
  }
}

void _workerMain(List<dynamic> args) {
  final toMain = args[0] as SendPort;
  final modelPath = args[1] as String;
  final cutoff = args[2] as double;
  _Worker worker;
  try {
    worker = _Worker(modelPath, cutoff);
  } catch (e) {
    toMain.send('error: $e');
    return;
  }
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  rp.listen((msg) {
    try {
      if (msg is TransferableTypedData) {
        if (worker.process(msg.materialize().asUint8List())) toMain.send('wake');
      } else if (msg == 'reset') {
        worker.reset();
      } else if (msg == 'close') {
        worker.close();
        rp.close();
      }
    } catch (e) {
      toMain.send('error: $e');
    }
  });
}
