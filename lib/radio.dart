import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

/// Rádio pela internet, a pedido por voz.
///
/// As estações vêm do Radio Browser (diretório gratuito e aberto, sem conta nem chave).
/// O Klaus (a IA) chama as ferramentas `self.radio.*` e este módulo toca.
class KlausRadio extends ChangeNotifier {
  static const _mirrors = [
    'https://de1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
  ];
  static const _agent = 'Klaus/1.0 (github.com/familiadousseau/klaus)';

  // Sem "lutar" pelo áudio com a voz do Klaus: o volume é gerido aqui (baixa quando ele está acordado).
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );

  /// Nome da estação a tocar (null = parada).
  String? nowPlaying;
  double _volume = 1.0; // volume escolhido (0..1)
  bool _ducked = false; // baixinho enquanto o Klaus conversa

  bool get isPlaying => nowPlaying != null;

  KlausRadio() {
    _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
      // A emissão caiu: considera parada.
      if (nowPlaying != null) {
        nowPlaying = null;
        notifyListeners();
      }
    });
  }

  double get _effectiveVolume => _ducked ? _volume * 0.15 : _volume;

  /// Baixa (true) ou repõe (false) o volume enquanto o Klaus conversa.
  Future<void> duck(bool on) async {
    _ducked = on;
    if (isPlaying) await _player.setVolume(_effectiveVolume);
  }

  Future<String> setVolume(int percent) async {
    _volume = (percent.clamp(0, 100)) / 100.0;
    await _player.setVolume(_effectiveVolume);
    return 'Volume da rádio: ${percent.clamp(0, 100)}%.';
  }

  Future<void> stop() async {
    await _player.stop();
    if (nowPlaying != null) {
      nowPlaying = null;
      notifyListeners();
    }
  }

  /// Procura e toca. Devolve um texto curto para a IA dizer ao utilizador.
  Future<String> play({String? name, String? style, String? country}) async {
    name = name?.trim();
    style = style?.trim().toLowerCase();
    country = country?.trim().toUpperCase();
    if (country != null && country.length != 2) country = null;

    final tries = <Map<String, String>>[];
    if (name != null && name.isNotEmpty) {
      if (country != null) tries.add({'name': name, 'countrycode': country});
      tries.add({'name': name});
    }
    if (style != null && style.isNotEmpty) {
      if (country != null) tries.add({'tag': style, 'countrycode': country});
      tries.add({'tag': style});
    }
    if (tries.isEmpty && country != null) tries.add({'countrycode': country});
    if (tries.isEmpty) return 'Não percebi que rádio tocar. Diga o nome da estação ou um estilo.';

    for (final q in tries) {
      final stations = await _search(q);
      for (final s in stations.take(4)) {
        final url = (s['url_resolved'] as String?)?.trim().isNotEmpty == true
            ? s['url_resolved'] as String
            : (s['url'] as String? ?? '');
        if (url.isEmpty) continue;
        final ok = await _tryPlay(url);
        if (!ok) continue;
        final title = (s['name'] as String? ?? 'rádio').trim();
        final where = (s['country'] as String? ?? '').trim();
        nowPlaying = title;
        notifyListeners();
        _countClick(s['stationuuid'] as String?);
        return where.isEmpty ? 'A tocar: $title.' : 'A tocar: $title ($where).';
      }
    }
    return 'Não encontrei nenhuma rádio a funcionar com esse pedido.';
  }

  Future<List<Map<String, dynamic>>> _search(Map<String, String> q) async {
    final params = {
      ...q,
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
      'limit': '8',
    };
    for (final base in _mirrors) {
      try {
        final uri = Uri.parse('$base/json/stations/search').replace(queryParameters: params);
        final r = await http
            .get(uri, headers: {'User-Agent': _agent})
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) continue;
        final list = jsonDecode(utf8.decode(r.bodyBytes));
        if (list is List) {
          return list.whereType<Map<String, dynamic>>().toList();
        }
      } catch (_) {
        // tenta o próximo servidor
      }
    }
    return const [];
  }

  Future<bool> _tryPlay(String url) async {
    try {
      await _player.stop();
      await _player.setVolume(_effectiveVolume);
      await _player.setUrl(url).timeout(const Duration(seconds: 12));
      unawaited(_player.play()); // só termina quando a rádio pára
      return true;
    } catch (_) {
      return false;
    }
  }

  void _countClick(String? uuid) {
    if (uuid == null || uuid.isEmpty) return;
    // Pequena ajuda ao diretório (conta a estação como ouvida).
    unawaited(http
        .get(Uri.parse('${_mirrors.first}/json/url/$uuid'), headers: {'User-Agent': _agent})
        .timeout(const Duration(seconds: 5))
        .then((_) {}, onError: (_) {}));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
