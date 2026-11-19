import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Identidade "de aparelho" do Klaus no telemóvel.
/// É criada uma vez e guardada, para o servidor reconhecer sempre o mesmo dispositivo.
class DeviceIdentity {
  final String deviceId; // formato MAC, ex.: 02:1a:2b:3c:4d:5e
  final String clientId; // UUID
  final String serialNumber;
  final String hmacKey;
  final String prefix;

  DeviceIdentity({
    required this.prefix,
    required this.deviceId,
    required this.clientId,
    required this.serialNumber,
    required this.hmacKey,
  });

  /// Cada idioma tem a sua identidade (o prefixo separa as chaves guardadas).
  static Future<DeviceIdentity> load([String prefix = 'klaus_']) async {
    final kDevice = '${prefix}device_id';
    final kClient = '${prefix}client_id';
    final kSerial = '${prefix}serial';
    final kHmac = '${prefix}hmac_key';
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(kDevice);
    var clientId = prefs.getString(kClient);
    var serial = prefs.getString(kSerial);
    var hmacKey = prefs.getString(kHmac);

    if (deviceId == null || clientId == null || serial == null || hmacKey == null) {
      final rnd = Random.secure();
      // MAC "localmente administrado" (primeiro byte 0x02) para não colidir com aparelhos reais.
      final bytes = List<int>.generate(6, (_) => rnd.nextInt(256));
      bytes[0] = 0x02;
      deviceId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
      clientId = const Uuid().v4();
      final macClean = deviceId.replaceAll(':', '').toUpperCase();
      final shortHash =
          md5.convert(utf8.encode(macClean)).toString().substring(0, 8).toUpperCase();
      serial = 'SN-$shortHash-$macClean';
      hmacKey = sha256
          .convert(utf8.encode('$deviceId||$clientId||${rnd.nextInt(1 << 31)}'))
          .toString();
      await prefs.setString(kDevice, deviceId);
      await prefs.setString(kClient, clientId);
      await prefs.setString(kSerial, serial);
      await prefs.setString(kHmac, hmacKey);
    }
    return DeviceIdentity(
      prefix: prefix,
      deviceId: deviceId,
      clientId: clientId,
      serialNumber: serial,
      hmacKey: hmacKey,
    );
  }

  String sign(String challenge) {
    final h = Hmac(sha256, utf8.encode(hmacKey));
    return h.convert(utf8.encode(challenge)).toString();
  }

  /// Apaga a identidade (o Klaus passa a ser um "aparelho novo").
  static Future<void> reset([String prefix = 'klaus_']) async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['device_id', 'client_id', 'serial', 'hmac_key', 'ws_url', 'ws_token']) {
      await prefs.remove('$prefix$k');
    }
  }
}
