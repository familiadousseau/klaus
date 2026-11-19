import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

class UpdateInfo {
  final int build;
  final String apkUrl;
  final String notes;
  UpdateInfo(this.build, this.apkUrl, this.notes);
}

/// Procura uma versão nova do Klaus nos "Releases" do GitHub.
class Updater {
  static Future<UpdateInfo?> check() async {
    final uri = Uri.parse(
        'https://api.github.com/repos/${KlausConfig.githubRepo}/releases/latest');
    final resp = await http.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final tag = data['tag_name']?.toString() ?? '';
    final m = RegExp(r'(\d+)$').firstMatch(tag);
    if (m == null) return null;
    final build = int.parse(m.group(1)!);
    String? apk;
    final assets = data['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is Map && (a['name']?.toString() ?? '').endsWith('.apk')) {
          apk = a['browser_download_url']?.toString();
          break;
        }
      }
    }
    if (apk == null) return null;
    if (build <= KlausConfig.buildNumber) return null;
    return UpdateInfo(build, apk, data['body']?.toString() ?? '');
  }
}
