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
    if (RegExp(r'ingl|english|englisch').hasMatch(t)) return 'en';
    if (RegExp(r'italian|italia|italien').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|allema|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
    if (RegExp(r'alema(?!nh)|allema|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
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
  if (RegExp(r'ingl|english|englisch').hasMatch(t)) return 'en';
  if (RegExp(r'italian|italia|italien').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|allema|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
  return null;
}

/// A frase pede treino/aula ("vamos treinar italiano", "quero praticar inglês", "Deutsch lernen")?
/// Só aí o Klaus da outra língua começa em modo aula; senão só cumprimenta.
bool detectLessonRequest(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  return RegExp(r'trein|pratic|aula|estud|aprend|exercit|allena|eserci|studia|impar|lezion|'
          r'practi|train|learn|lesson| lern| uben| ueben|unterricht')
      .hasMatch(t);
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
  if (RegExp(r'ingl|english|englisch').hasMatch(t)) return 'en';
  if (RegExp(r'italian|italia|italien').hasMatch(t)) return 'it';
  if (RegExp(r'alema(?!nh)|allema|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) return 'de';
  if (RegExp(r'portug|portog|portuguese').hasMatch(t)) return 'pt';
  return null;
}

/// Frase curta dirigida ao Klaus ("Klaus, descansar"): conta mesmo no modo tradutor.
bool isShortKlausCommand(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  final palavras = t.trim().split(' ').where((w) => w.isNotEmpty).length;
  return palavras <= 4 &&
      RegExp(r' (klaus|claus|klas|klaas|klause|clause|close|class|clouse|claws|kloss|glaus) ').hasMatch(t);
}

/// Comando CURTO do modo tradução, em qualquer agente e em qualquer das 4 línguas:
///   "Klaus, modo tradução" · "translator mode" · "modalità traduttore" · "Übersetzer"
///   "Klaus, modo tradução italiano"  (escolhe o agente)
///   "Klaus, parar tradução" · "stop translation" · "basta tradurre" · "Übersetzung stoppen"
/// Devolve ('stop', null), ('start', código da língua ou null) ou null.
(String, String?)? detectTranslatorCommand(String spoken) {
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  final palavras = t.trim().split(' ').where((w) => w.isNotEmpty).length;
  if (palavras > 7) return null;
  if (!RegExp(r'tradu|translat|ubersetz|uebersetz|dolmetsch|interpret').hasMatch(t)) return null;
  final nome = RegExp(r' (klaus|claus|klas|klaas|klause|clause|close|class|clouse|claws|kloss|glaus) ').hasMatch(t);
  final modo = RegExp(r' (modo|mode|modus|modalita|modalidade) |tradutor|traduttore|translator|ubersetzer|uebersetzer|'
          r'ubersetzungsmodus|uebersetzungsmodus|dolmetscher|interprete|interpreter')
      .hasMatch(t);
  final stop = RegExp(r' (parar|pare|parou|chega|acaba|acabou|fim|sair|sai|desativa|desativar|desliga|desligar|termina|terminar|'
          r'stop|end|off|basta|smetti|ferma|fine|esci|ende|beenden|beende|aus|halt|stopp|stoppen) |'
          r' para (de|a|o) (tradu|traduzir)')
      .hasMatch(t);
  // "Stop translation", "basta tradurre": curto, mesmo sem o nome.
  if (stop && (nome || modo || palavras <= 4)) return ('stop', null);
  if (!nome && !modo) return null;
  String? alvo;
  if (RegExp(r'portug|portog|portuguese').hasMatch(t)) alvo = 'pt';
  if (RegExp(r'ingl|english|englisch').hasMatch(t)) alvo = 'en';
  if (RegExp(r'italian|italia|italien').hasMatch(t)) alvo = 'it';
  if (RegExp(r'alema(?!nh)|allema|german(?!y)|deutsch(?!land)|doitsch|tedesc').hasMatch(t)) alvo = 'de';
  return ('start', alvo);
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

/// FREIO: "Klaus, pare!" em qualquer das 4 línguas. O Klaus cala-se já e fica à espera,
/// sem responder. A frase tem de ser só a ordem (o nome e "por favor" são opcionais),
/// para "para quê?" ou "chega aqui" não contarem.
const _stopPhrases = {
  // português
  'pare', 'para', 'parar', 'para ai', 'pare ai', 'pode parar', 'chega', 'basta', 'silencio',
  'cala', 'cala te', 'cala se', 'cala a boca', 'quieto', 'fica quieto', 'espera', 'espere', 'espera ai', 'espere ai',
  'para de falar', 'pare de falar', 'chega de falar', 'para com isso', 'pare com isso',
  // inglês
  'stop', 'stop it', 'stop talking', 'quiet', 'be quiet', 'enough', "that's enough", 'thats enough',
  'shut up', 'hold on', 'wait', 'wait a second', 'wait a moment',
  // italiano
  'basta cosi', 'fermati', 'ferma', 'zitto', 'stai zitto', 'silenzio', 'aspetta', 'smettila', 'smetti',
  'smetti di parlare',
  // alemão
  'stopp', 'halt', 'hor auf', 'hoer auf', 'horauf', 'ruhe', 'genug', 'still', 'sei still', 'warte',
  'aufhoren', 'aufhoeren', 'hor auf zu reden', 'halt stopp',
};

bool detectStopCommand(String spoken) {
  var t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z' ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  t = t.replaceAll(
      RegExp(r' (klaus|claus|klas|klaas|klause|clause|close|class|clouse|claws|kloss|glaus)(?= )'), ' ');
  t = t.replaceAll(
      RegExp(r' (por favor|please|bitte|per favore|ok|okay|oi|ei|hey|agora|now|jetzt|adesso|ora|ja)(?= )'), ' ');
  t = t.replaceAll(RegExp(r' +'), ' ').trim();
  return _stopPhrases.contains(t);
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
  final t = ' ${_plain(spoken).replaceAll(RegExp(r"[^a-z0-9 ]+"), ' ').replaceAll(RegExp(r' +'), ' ')} ';
  const words = [
    ' tchau', ' xau', ' adeus', ' ate logo', ' ate mais', ' ate amanha', ' ate depois',
    ' vou dormir', ' vou nessa', ' to indo', ' tou indo', ' preciso ir', ' boa noite klaus', ' boa noite claus',
    ' bye', ' goodbye', ' good bye', ' see you', ' good night',
    ' ciao ciao', ' arrivederci', ' a dopo', ' a domani', ' buonanotte',
    ' tschuss', ' auf wiedersehen', ' bis morgen', ' bis spater', ' gute nacht',
    // Descansar / adeus em cada língua (pedido para o Klaus ir dormir)
    ' descansa', ' descansar', ' descanse', ' vai dormir', ' pode dormir', ' hora de dormir',
    ' farewell', ' take a rest', ' get some rest', ' have a rest', ' go rest', ' go to sleep', ' time to sleep',
    ' addio', ' riposa', ' riposati', ' riposare', ' vai a dormire', ' a presto',
    ' ruh dich aus', ' ruhe dich aus', ' ausruhen', ' geh schlafen', ' schlaf gut', ' lebewohl', ' leb wohl',
    ' adieu', ' bis bald',
  ];
  // Perguntas sobre palavras ("como se diz descansar?", "what does bye mean?") não são despedidas.
  if (RegExp(r'como se diz|como e que se diz|o que significa|que quer dizer|how do you say|what does|what is the|'
          r'come si dice|cosa vuol|cosa significa|wie sagt man|was bedeutet|tradu|translat|ubersetz')
      .hasMatch(t)) {
    return false;
  }
  if (words.any(t.contains)) return true;
  final palavras = t.trim().split(' ').where((w) => w.isNotEmpty).length;
  final nomeRe = RegExp(r' (klaus|claus|klas|klaas|klause|clause|close|class|clouse|claws|kloss|glaus) ');
  final nomeM = nomeRe.firstMatch(t);
  final nome = nomeM != null;
  // FRASE FIXA, em qualquer agente: "Klaus, descansar".
  // Vê-se pelo som da palavra logo a seguir ao nome, porque o reconhecedor inglês/italiano/alemão
  // pode escrever "this cancer", "the scansar", "des kansar"…
  if (nomeM != null && palavras <= 4) {
    final som = t
        .substring(nomeM.end)
        .replaceAll(' ', '')
        .replaceAll(RegExp('c(?=[eiy])'), 's') // "cancer" soa "kanser"
        .replaceAll(RegExp('[cq]'), 'k')
        .replaceAll('z', 's')
        .replaceAll('ss', 's');
    if (RegExp(r'^(d|th|t)?[aeiouy]*s?kan+s[aeiou]').hasMatch(som)) return true;
  }
  // "Boa noite, Klaus" com o nome mal escrito ("Claus", "Close"…)
  if (nome && t.contains(' boa noite ')) return true;
  // Ordem curta: "Klaus, rest!", "dorme", "schlaf!", "dormi"
  return palavras <= 3 && RegExp(r' (rest|sleep|dorme|dormir|dormi|schlaf|schlafen) ').hasMatch(t);
}
