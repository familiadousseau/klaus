/// Configurações fixas do app Klaus.
class KlausConfig {
  /// Endereço OTA oficial do XiaoZhi (o mesmo que o py-xiaozhi usa).
  static const String otaUrl = 'https://api.tenclass.net/xiaozhi/ota/';

  /// Painel onde se introduz o código de ativação.
  static const String consoleUrl = 'https://xiaozhi.me/console/agents';

  /// Identificação enviada ao servidor (igual à do py-xiaozhi).
  static const String boardType = 'bread-compact-wifi';
  static const String appName = 'klaus-android';
  static const String appVersion = '2.1.4';

  /// Repositório no GitHub onde saem as atualizações do app.
  static const String githubRepo = 'familiadousseau/klaus';

  /// Número da compilação, posto pelo GitHub Actions (--dart-define=BUILD_NUMBER=...).
  static const int buildNumber =
      int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

  /// Áudio: microfone 16 kHz mono, frames de 60 ms (igual ao ESP32).
  static const int inputSampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 60;
}
