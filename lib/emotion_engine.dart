/// Escolhe a carinha do Klaus a partir do que ele diz, frase a frase.
/// Funciona em português, inglês e italiano. Não depende do servidor.
class EmotionEngine {
  int _rotation = 0;

  static const _emojiMap = <String, String>{
    '😂': 'laughing', '🤣': 'laughing', '😆': 'laughing',
    '😊': 'happy', '🙂': 'happy', '😀': 'happy', '😃': 'happy', '😄': 'happy',
    '😜': 'silly', '😝': 'silly', '🤪': 'silly',
    '😢': 'sad', '🙁': 'sad', '☹': 'sad',
    '😭': 'crying',
    '😠': 'angry', '😡': 'angry', '🤬': 'angry',
    '😲': 'surprised', '😮': 'surprised', '😯': 'surprised',
    '😱': 'shocked',
    '🤔': 'thinking',
    '😴': 'sleepy', '🥱': 'sleepy',
    '😌': 'relaxed',
    '😍': 'loving', '🥰': 'loving', '❤': 'loving',
    '😘': 'kissy',
    '😉': 'winking',
    '😎': 'cool',
    '😏': 'confident',
    '😕': 'confused', '🤨': 'confused',
    '😳': 'embarrassed',
    '😋': 'delicious',
  };

  /// Regras por palavras (texto já sem acentos e em minúsculas; cada palavra-chave
  /// tem de aparecer no início de uma palavra).
  static const _rules = <(String, List<String>)>[
    ('laughing', ['haha', 'hehe', 'kkk', 'rsrs', 'ahah', 'lol', 'que engracad', 'piada', 'joke', 'funny', 'barzelletta', 'divertente']),
    ('angry', ['bravo comigo', 'to bravo', 'tou bravo', 'zangado', 'irritad', 'grr', 'hmpf', 'angry', 'annoyed', 'arrabbiat', 'uffa']),
    ('crying', ['buaa', 'chorar', 'chorando', 'crying', 'piango', 'piangere']),
    ('sad', ['triste', 'que pena', 'lamento', 'saudade', 'sad', 'sorry', 'too bad', 'mi dispiace', 'peccato']),
    ('shocked', ['nao acredito', 'meu deus', 'oh my god', 'omg', 'mamma mia', 'incredibile']),
    ('surprised', ['uau', 'nossa!', 'serio?', 'caramba', 'eita', 'opa!', 'wow', 'really?', 'whoa', 'davvero', 'accidenti']),
    ('loving', ['adoro', 'amo ', 'gosto muito', 'que lindo', 'love', 'adorabile', 'ti voglio bene', 'amico mio', 'obrigad', 'thank', 'grazie']),
    ('cool', ['muito bem', 'mandou bem', 'perfeito', 'excelente', 'arrasou', 'great job', 'well done', 'perfect', 'excellent', 'awesome', 'bravissimo', 'perfetto', 'ottimo', 'benissimo']),
    ('winking', ['quase', 'nao e bem', 'cuidado', 'dica', 'segredo', 'almost', 'not quite', 'quasi', 'attenzione']),
    ('confused', ['nao entendi', 'como assim', 'hein', 'confus', "don't understand", 'what do you mean', 'non ho capito', 'cosa vuoi dire']),
    ('embarrassed', ['desculpa', 'ops', 'oops', 'my bad', 'scusa', 'che vergogna', 'vergonha']),
    ('sleepy', ['com sono', 'cansad', 'boa noite', 'dormir', 'sleepy', 'tired', 'good night', 'stanco', 'buonanotte']),
    ('delicious', ['comida', 'delicia', 'gostoso', 'pizza', 'cafe', 'food', 'delicious', 'tasty', 'cibo', 'delizioso', 'gelato', 'pasta']),
    ('confident', ['claro que', 'obvio', 'facil', 'deixa comigo', 'of course', 'easy', 'certo che', 'facile']),
    ('thinking', ['deixa ver', 'hmm', 'pensar', 'acho que', 'let me think', 'i think', 'vediamo', 'penso che', 'secondo me']),
  ];

  static String _plain(String s) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }

  /// Emoção para uma frase dita pelo Klaus. Nunca devolve null.
  String forSentence(String text) {
    // 1) emoji no texto
    for (final e in _emojiMap.entries) {
      if (text.contains(e.key)) return e.value;
    }
    // 2) palavras-chave (no início de palavra, para "sad" não apanhar "passado")
    final t = _plain(text);
    final padded = ' ${t.replaceAll(RegExp(r"[^a-z0-9?!']+"), ' ')} ';
    for (final r in _rules) {
      if (r.$2.any((k) => padded.contains(' $k'))) return r.$1;
    }
    // 3) pontuação
    final trimmed = t.trim();
    if (trimmed.endsWith('?')) {
      const q = ['thinking', 'confident', 'winking'];
      return q[_rotation++ % q.length];
    }
    if (trimmed.endsWith('!')) {
      const ex = ['happy', 'laughing', 'cool', 'silly'];
      return ex[_rotation++ % ex.length];
    }
    // 4) frase neutra: vai variando para ele parecer vivo
    const calm = ['happy', 'relaxed', 'winking', 'neutral', 'confident'];
    return calm[_rotation++ % calm.length];
  }

  /// Emoção que o servidor mandou: só vale se trouxer informação (não "happy"/"neutral").
  static bool isInformative(String? serverEmotion) =>
      serverEmotion != null &&
      serverEmotion.isNotEmpty &&
      serverEmotion != 'happy' &&
      serverEmotion != 'neutral';
}
