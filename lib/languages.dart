/// Idiomas do Klaus. Cada um corresponde a um agente diferente no painel do XiaoZhi,
/// com a voz nativa dessa língua.
class KlausLang {
  final String code;
  final String name;
  final String flag;
  final String agentName; // nome do agente no painel
  final String prefix; // prefixo das chaves guardadas no telemóvel

  const KlausLang(this.code, this.name, this.flag, this.agentName, this.prefix);
}

const kLangs = <KlausLang>[
  // O português usa as chaves antigas (sem prefixo) para manter a ativação já feita.
  KlausLang('pt', 'Português', '🇧🇷', 'Klaus', 'klaus_'),
  KlausLang('en', 'English', '🇬🇧', 'Klaus English', 'klaus_en_'),
  KlausLang('it', 'Italiano', '🇮🇹', 'Klaus Italiano', 'klaus_it_'),
];

KlausLang langByCode(String code) =>
    kLangs.firstWhere((l) => l.code == code, orElse: () => kLangs.first);

String _plain(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ';
  const to = 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().toLowerCase();
}

/// Descobre se a frase dita pede para trocar de idioma. Devolve o código ou null.
String? detectLanguageSwitch(String spoken) {
  final t = _plain(spoken);
  bool any(List<String> w) => w.any(t.contains);

  final wantsChange = any([
    'treinar', 'praticar', 'aprender', 'estudar', 'fala em', 'falar em', 'fala comigo',
    'fale em', 'fale comigo', 'muda para', 'mudar para', 'troca para', 'trocar para',
    'vamos de', 'modo', 'voltar', 'volta', 'back to', 'switch to', 'speak',
    'torna', 'torniamo', 'parla', 'cambia', 'passa a', 'in portoghese',
  ]);
  if (!wantsChange) return null;

  if (any(['portugues', 'portuguese', 'portoghese'])) return 'pt';
  if (any(['ingles', 'english', 'inglese'])) return 'en';
  if (any(['italiano', 'italian'])) return 'it';
  return null;
}
