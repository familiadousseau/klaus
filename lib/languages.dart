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

/// Descobre se a frase dita pede para trocar de idioma.
/// Tolerante a transcrições imperfeitas (ex.: o Klaus Italiano escreve "portoghese").
/// Pedidos de explicação/tradução NÃO trocam: o professor explica e continua.
String? detectLanguageSwitch(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';

  // "Explica em português", "como se diz...", "o que significa..." ficam no mesmo professor.
  if (RegExp(r'explic|expliq|tradu|signific|quer dizer|como se diz|como e que se diz|'
          r'how do you say|what does|explain|translat|spieg|come si dice|cosa vuol|cosa significa')
      .hasMatch(t)) {
    return null;
  }

  // Alguma intenção de mudar/falar/voltar/treinar (em pt, en ou it, mesmo mal escrita).
  final intent = RegExp(r' (vamos|bora|quero|queria|vou|fala|falar|fale|falamos|conversa|conversar|'
          r'volta|voltar|volte|voltamos|muda|mudar|mude|troca|trocar|troque|passa|passar|'
          r'treina|treinar|pratica|praticar|estudar|aprender|modo|klaus|claus|'
          r"let's|lets|speak|talk|switch|back|change|practice|"
          r'parla|parlare|parliamo|torna|tornare|torniamo|passiamo|cambia|andiamo|vamo)\b')
      .hasMatch(t);
  if (!intent) return null;

  if (RegExp(r'portug|portog|portuguese').hasMatch(t)) return 'pt';
  if (RegExp(r'ingl|english').hasMatch(t)) return 'en';
  if (RegExp(r'italian|italia').hasMatch(t)) return 'it';
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
