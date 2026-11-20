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

/// Descobre se a frase dita pede EXPLICITAMENTE para trocar de idioma.
/// "Explica em português" NÃO troca: o professor explica e continua.
String? detectLanguageSwitch(String spoken) {
  final t = _plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ');

  // Pedidos de explicação/tradução ficam no mesmo professor.
  if (RegExp(r'explic|expliq|tradu|signific|quer dizer|o que e |explain|translat|mean|spieg|cosa vuol').hasMatch(t)) {
    return null;
  }

  const targets = {
    'pt': r'(portugues|portuguese|portoghese)',
    'en': r'(ingles|english|inglese)',
    'it': r'(italiano|italian)',
  };
  const triggers = [
    r"(vamos|bora|quero|vou) (treinar|praticar|estudar|aprender|falar|conversar)( um pouco)?( em| o| a| de)? ",
    r"(treinar|praticar|estudar)( o| a| em)? ",
    r"(muda|mudar|mude|troca|trocar|troque|passa|passar|vai|ir) (para|pro|pra|ao)( o)?( klaus)? ",
    r"(volta|voltar|volte|voltamos|retorna|retornar) (ao|para o|pro|pra|para)( klaus)? ",
    r"(modo|klaus) ",
    r"(switch|go back|back|change) to ",
    r"(let's|lets) (practice|practise|speak|train|learn) ",
    r"(torniamo|torna|tornare|passiamo|passa) (al|all'|a|in) ",
  ];
  for (final e in targets.entries) {
    for (final tr in triggers) {
      if (RegExp(tr + e.value).hasMatch(t)) return e.key;
    }
  }
  return null;
}

/// Descobre se a frase dita é uma despedida (para o Klaus ir dormir).
bool detectFarewell(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z0-9 ]+"), ' ')} ';
  const words = [
    ' tchau', ' xau', ' adeus', ' ate logo', ' ate mais', ' ate amanha', ' ate depois',
    ' vou dormir', ' vou nessa', ' to indo', ' tou indo', ' preciso ir', ' boa noite klaus', ' boa noite claus',
    ' bye', ' goodbye', ' good bye', ' see you', ' good night',
    ' ciao ciao', ' arrivederci', ' a dopo', ' a domani', ' buonanotte',
  ];
  return words.any(t.contains);
}
