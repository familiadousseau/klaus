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
  KlausLang('de', 'Deutsch', '🇩🇪', 'Klaus Deutsch', 'klaus_de_'),
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

/// Comando pré-definido, curto: "Klaus, italiano!" / "Klaus, English!" / "Klaus, português!".
/// O reconhecimento de voz de qualquer agente escreve bem o nome e a língua.
/// É o único que funciona durante o modo tradutor.
String? detectShortSwitch(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  final palavras = t.trim().split(' ').where((w) => w.isNotEmpty).length;
  if (palavras <= 4 && RegExp(r' (klaus|claus|klas|klaas|clause|close|class|clouse|claws)').hasMatch(t)) {
    if (RegExp(r'portug|portog|portuguese').hasMatch(t)) return 'pt';
    if (RegExp(r'ingl|english').hasMatch(t)) return 'en';
    if (RegExp(r'italian|italia').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
    if (RegExp(r'alema(?!nh)|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
  }
  return null;
}

/// Descobre se a frase dita pede para trocar de idioma.
/// Tolerante: dentro do Klaus English/Italiano, o reconhecimento de voz escreve o seu
/// português "à inglesa/italiana" ("portoghese", "inglese", "treinare"...).
/// Pedidos de explicação/tradução pontual NÃO trocam: o professor explica e continua.
String? detectLanguageSwitch(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';

  if (RegExp(r'explic|expliq|tradu|signific|quer dizer|como se diz|como e que se diz|'
          r'how do you say|what does|explain|translat|spieg|come si dice|cosa vuol|cosa significa|'
          r'wie sagt man|was bedeutet|erklar|ubersetz')
      .hasMatch(t)) {
    return null;
  }

  final curto = detectShortSwitch(spoken);
  if (curto != null) return curto;

  final intent = RegExp(r' (vamos|bora|quero|queria|vou|fala|falar|fale|falamos|conversa|conversar|'
          r'volta|voltar|volte|voltamos|muda|mudar|mude|troca|trocar|troque|passa|passar|'
          r'treina|treinar|treinare|pratica|praticar|estudar|aprender|modo|klaus|claus|'
          r"let's|lets|speak|talk|switch|back|change|practice|train|learn|want|"
          r'parla|parlare|parliamo|torna|tornare|torniamo|passiamo|cambia|andiamo|vamo|voglio|allenare|esercitare|studiare|'
          r'sprechen|sprich|lernen|uben|ueben|wechseln|zuruck|zurueck|will|mochte|moechte|lass)')
      .hasMatch(t);
  if (!intent) return null;

  if (RegExp(r'portug|portog|portuguese').hasMatch(t)) return 'pt';
  if (RegExp(r'ingl|english').hasMatch(t)) return 'en';
  if (RegExp(r'italian|italia').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
  return null;
}

/// Pedido de MODO TRADUTOR ("a partir de agora traduz para italiano o que eu falar").
/// Devolve o idioma de destino, ou null se for só uma tradução pontual.
String? detectTranslatorRequest(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  if (!RegExp(r'tradu|translat|ubersetz|uebersetz').hasMatch(t)) return null;
  final ongoing = RegExp(r'a partir de agora|daqui (pra|para a|para) frente|modo tradu|tradutor|'
          r'o que eu (falar|disser|digo|for falando)|tudo (o )?que eu|enquanto eu|'
          r'from now on|translator|everything i say|what i say|'
          r"d'ora in poi|da ora|da adesso|traduttore|tutto quello che dico|quello che dico|"
          r'ab jetzt|von jetzt an|ubersetzer|alles was ich sage')
      .hasMatch(t);
  if (!ongoing) return null;
  if (RegExp(r'ingl|english').hasMatch(t)) return 'en';
  if (RegExp(r'italian|italia').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
  if (RegExp(r'portug|portog|portuguese').hasMatch(t)) return 'pt';
  return null;
}

/// Pedido para DESLIGAR o modo tradutor ("parar tradução", "stop translation", "basta tradurre").
bool detectTranslatorStop(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  return RegExp(r' (parar|para|pare|parou|chega|acabou|acaba|fim|sair|sai|desativa|desativar|desliga|desligar|termina|terminar)'
          r' (a |o |de |da |do |com a |com o )?(modo )?(tradu|traduzir)|'
          r' stop (the )?translat| end (the )?translat| translator off| stop translator|'
          r' basta (con la |la )?tradu| smetti di tradurre| ferma (la )?tradu| fine (della )?tradu| esci dalla (modalita )?tradu')
      .hasMatch(t);
}

/// Bandeira na resposta do Klaus = ele percebeu que você quer outro idioma.
String? detectFlagSwitch(String text) {
  if (text.contains('🇮🇹')) return 'it';
  if (text.contains('🇩🇪') || text.contains('🇨🇭') || text.contains('🇦🇹')) return 'de';
  if (text.contains('🇬🇧') || text.contains('🇺🇸')) return 'en';
  if (text.contains('🇧🇷') || text.contains('🇵🇹')) return 'pt';
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
    ' tschuss', ' auf wiedersehen', ' bis morgen', ' bis spater', ' gute nacht',
  ];
  return words.any(t.contains);
}
