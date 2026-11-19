import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'identity.dart';

/// Resultado do pedido OTA ao servidor do XiaoZhi.
class OtaResult {
  final String? websocketUrl;
  final String? websocketToken;
  final String? activationCode;
  final String? activationMessage;
  final String? challenge;

  OtaResult({
    this.websocketUrl,
    this.websocketToken,
    this.activationCode,
    this.activationMessage,
    this.challenge,
  });

  bool get needsActivation => activationCode != null && activationCode!.isNotEmpty;
}

class OtaClient {
  final DeviceIdentity id;
  OtaClient(this.id);

  Map<String, String> _headers({bool activation = false}) => {
        'Device-Id': id.deviceId,
        'Client-Id': id.clientId,
        'Content-Type': 'application/json',
        'User-Agent': '${KlausConfig.boardType}/${KlausConfig.appName}-${KlausConfig.appVersion}',
        'Accept-Language': 'pt-BR',
        'Activation-Version': activation ? '2' : KlausConfig.appVersion,
      };

  Future<OtaResult> fetch() async {
    final body = jsonEncode({
      'application': {
        'version': KlausConfig.appVersion,
        'elf_sha256': id.hmacKey,
      },
      'board': {
        'type': KlausConfig.boardType,
        'name': KlausConfig.appName,
        'ip': '0.0.0.0',
        'mac': id.deviceId,
      },
    });
    final resp = await http
        .post(Uri.parse(KlausConfig.otaUrl), headers: _headers(), body: body)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('Servidor OTA respondeu ${resp.statusCode}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

    String? wsUrl;
    String? wsToken;
    final ws = data['websocket'];
    if (ws is Map) {
      wsUrl = ws['url']?.toString();
      final t = ws['token']?.toString();
      wsToken = (t == null || t.isEmpty) ? 'test-token' : t;
    }
    if (wsUrl != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${id.prefix}ws_url', wsUrl);
      await prefs.setString('${id.prefix}ws_token', wsToken ?? 'test-token');
    }

    final act = data['activation'];
    if (act is Map) {
      return OtaResult(
        websocketUrl: wsUrl,
        websocketToken: wsToken,
        activationCode: act['code']?.toString(),
        activationMessage: act['message']?.toString(),
        challenge: act['challenge']?.toString(),
      );
    }
    return OtaResult(websocketUrl: wsUrl, websocketToken: wsToken);
  }

  /// Tenta confirmar a ativação (protocolo v2). Devolve true quando o servidor aceita.
  /// 202 = ainda à espera que o código seja introduzido no painel.
  Future<bool> tryActivate(String challenge) async {
    final url = '${KlausConfig.otaUrl.replaceAll(RegExp(r'/+$'), '')}/activate';
    final body = jsonEncode({
      'Payload': {
        'algorithm': 'hmac-sha256',
        'serial_number': id.serialNumber,
        'challenge': challenge,
        'hmac': id.sign(challenge),
      }
    });
    final resp = await http
        .post(Uri.parse(url), headers: _headers(activation: true), body: body)
        .timeout(const Duration(seconds: 15));
    return resp.statusCode == 200;
  }

  static Future<(String?, String?)> savedEndpoint(String prefix) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('${prefix}ws_url'), prefs.getString('${prefix}ws_token'));
  }
}
