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

  DeviceIdentity({
    required this.deviceId,
    required this.clientId,
    required this.serialNumber,
    required this.hmacKey,
  });

  static const _kDevice = 'klaus_device_id';
  static const _kClient = 'klaus_client_id';
  static const _kSerial = 'klaus_serial';
  static const _kHmac = 'klaus_hmac_key';

  static Future<DeviceIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_kDevice);
    var clientId = prefs.getString(_kClient);
    var serial = prefs.getString(_kSerial);
    var hmacKey = prefs.getString(_kHmac);

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
      await prefs.setString(_kDevice, deviceId);
      await prefs.setString(_kClient, clientId);
      await prefs.setString(_kSerial, serial);
      await prefs.setString(_kHmac, hmacKey);
    }
    return DeviceIdentity(
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
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [_kDevice, _kClient, _kSerial, _kHmac, 'klaus_ws_url', 'klaus_ws_token']) {
      await prefs.remove(k);
    }
  }
}
