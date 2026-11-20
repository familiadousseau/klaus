import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'klaus_client.dart';
import 'languages.dart';
import 'updater.dart';

const _bg = Color(0xFF101628);
const _card = Color(0xFF1C2642);
const _cyan = Color(0xFF5AE6FF);
const _pink = Color(0xFFFF6E96);

const _emotions = {
  'neutral', 'happy', 'laughing', 'funny', 'sad', 'angry', 'crying', 'loving',
  'embarrassed', 'surprised', 'shocked', 'thinking', 'winking', 'cool', 'relaxed',
  'delicious', 'kissy', 'confident', 'sleepy', 'silly', 'confused', 'listening', 'sleeping',
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final KlausClient klaus = KlausClient();
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _anim;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    klaus.addListener(_onChange);
    klaus.start();
    _anim = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (klaus.state == KlausState.listening || klaus.state == KlausState.speaking) {
        setState(() {});
      }
    });
    Future.delayed(const Duration(seconds: 3), () => _checkUpdate(silent: true));
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _anim?.cancel();
    klaus.removeListener(_onChange);
    klaus.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkUpdate({bool silent = false}) async {
    try {
      final up = await Updater.check();
      if (!mounted) return;
      if (up == null) {
        if (!silent) _toast('O Klaus já está na versão mais recente (${KlausConfig.buildNumber}).');
        return;
      }
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Há uma versão nova do Klaus!', style: TextStyle(color: Colors.white)),
          content: Text(
            'Versão ${up.build} (tem a ${KlausConfig.buildNumber}).\n\n'
            '${up.notes.isEmpty ? '' : '${up.notes}\n\n'}'
            'Toque em "Atualizar": o ficheiro é descarregado e depois é só abrir e instalar.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Depois')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                launchUrl(Uri.parse(up.apkUrl), mode: LaunchMode.externalApplication);
              },
              child: const Text('Atualizar'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!silent) _toast('Não consegui verificar atualizações: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------------- interface ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: klaus.sleeping ? Colors.black : _bg,
      appBar: klaus.sleeping ? null : AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: const Text('Klaus',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, letterSpacing: 2)),
        actions: [
          IconButton(
            tooltip: 'Escrever',
            icon: Icon(_showText ? Icons.keyboard_hide : Icons.keyboard),
            onPressed: () {
              setState(() => _showText = !_showText);
              klaus.setTextMode(_showText);
            },
          ),
          IconButton(
            tooltip: 'Opções',
            icon: const Icon(Icons.more_vert),
            onPressed: _openMenu,
          ),
        ],
      ),
      body: SafeArea(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => klaus.markActivity(),
          child: klaus.sleeping
            ? _sleepView()
            : klaus.state == KlausState.needsActivation
            ? _activationView()
            : klaus.state == KlausState.error
                ? _errorView()
                : _mainView(),
        ),
      ),
    );
  }

  Widget _sleepView() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: klaus.wakeUp,
      child: Container(
        color: Colors.black,
        width: double.infinity,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(opacity: 0.55, child: _face(size: 220)),
            const SizedBox(height: 20),
            const Text('Zzz... chame "Klaus" para acordar',
                style: TextStyle(color: Colors.white24, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _face({double size = 260}) {
    final name = _emotions.contains(klaus.emotion) ? klaus.emotion : 'neutral';
    double bounce = 1.0;
    if (klaus.state == KlausState.speaking) bounce = 1.0 + klaus.speakerLevel * 0.08;
    if (klaus.state == KlausState.listening && klaus.mic.voiceActive) bounce = 1.0 + klaus.micLevel * 0.05;
    return AnimatedScale(
      scale: bounce,
      duration: const Duration(milliseconds: 80),
      child: Image.asset(
        'assets/emojis/$name.gif',
        width: size,
        height: size,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            Image.asset('assets/emojis/neutral.gif', width: size, height: size),
      ),
    );
  }

  Widget _mainView() {
    final listening = klaus.state == KlausState.listening;
    final ready = klaus.state != KlausState.starting && klaus.state != KlausState.connecting;
    return Column(
      children: [
        if (_showText) ...[
          // Modo escrito: carinha menor e histórico da conversa.
          const SizedBox(height: 4),
          _face(size: 150),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              itemCount: klaus.chat.length,
              itemBuilder: (_, i) => _bubble(klaus.chat[i]),
            ),
          ),
        ] else
          // A carinha ocupa o centro do ecrã.
          Expanded(
            child: LayoutBuilder(builder: (ctx, c) {
              final size = (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight) * 0.9;
              return Center(child: _face(size: size));
            }),
          ),
        Text(klaus.status, style: const TextStyle(color: _cyan, fontSize: 16)),
        const SizedBox(height: 8),
        _langChip(),
        const SizedBox(height: 6),
        if (_showText) _textInput(),
        if (!_showText)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: Row(
            children: [
              _roundButton(
                icon: klaus.autoMode ? Icons.hearing : Icons.hearing_disabled,
                label: klaus.autoMode ? 'Contínuo' : 'Manual',
                color: klaus.autoMode ? _pink : _card,
                onTap: ready ? klaus.toggleAuto : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: klaus.autoMode
                    ? _bigButton(
                        icon: listening ? Icons.graphic_eq : Icons.stop,
                        label: listening
                            ? (klaus.mic.voiceActive ? 'A ouvir...' : 'À espera...')
                            : 'Interromper',
                        color: listening ? (klaus.mic.voiceActive ? _cyan : _card) : _card,
                        onDown: ready ? klaus.abort : null,
                      )
                    : _bigButton(
                        icon: listening ? Icons.mic : Icons.mic_none,
                        label: listening ? 'A ouvir... solte' : 'Segure para falar',
                        color: listening ? _pink : _cyan,
                        onDown: ready ? klaus.pressToTalk : null,
                        onUp: klaus.releaseToTalk,
                      ),
              ),
              const SizedBox(width: 12),
              _roundButton(
                icon: Icons.close,
                label: 'Parar',
                color: _card,
                onTap: ready ? klaus.abort : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _langChip() {
    return ActionChip(
      backgroundColor: _card,
      side: BorderSide.none,
      label: Text('${klaus.lang.flag}  ${klaus.lang.name}  ▾',
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      onPressed: _pickLanguage,
    );
  }

  void _pickLanguage() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('Com que Klaus quer falar?',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ),
          for (final l in kLangs)
            ListTile(
              leading: Text(l.flag, style: const TextStyle(fontSize: 26)),
              title: Text(l.name, style: const TextStyle(color: Colors.white)),
              subtitle: Text(l.agentName, style: const TextStyle(color: Colors.white54)),
              trailing: l.code == klaus.lang.code ? const Icon(Icons.check, color: _cyan) : null,
              onTap: () {
                Navigator.pop(ctx);
                klaus.switchLanguage(l.code);
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Text(
                'Também pode dizer: "vamos treinar inglês", "vamos treinar italiano" ou "voltar ao português".',
                style: TextStyle(color: Colors.white54)),
          ),
        ]),
      ),
    );
  }

  Widget _bubble(ChatLine l) {
    return Align(
      alignment: l.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: l.fromUser ? _cyan.withValues(alpha: 0.18) : _card,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(l.text, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    );
  }

  Widget _textInput() {
    void send() {
      klaus.sendText(_text.text);
      _text.clear();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Row(children: [
        IconButton(
          tooltip: klaus.textModeVoice ? 'Klaus fala as respostas' : 'Respostas só escritas',
          onPressed: klaus.toggleTextVoice,
          icon: Icon(klaus.textModeVoice ? Icons.volume_up : Icons.volume_off,
              color: klaus.textModeVoice ? _cyan : Colors.white54),
        ),
        Expanded(
          child: TextField(
            controller: _text,
            style: const TextStyle(color: Colors.white),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => send(),
            decoration: InputDecoration(
              hintText: 'Escreva para o Klaus...',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: _card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(onPressed: send, icon: const Icon(Icons.send)),
      ]),
    );
  }

  Widget _roundButton(
      {required IconData icon, required String label, required Color color, VoidCallback? onTap}) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: Colors.white),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
    ]);
  }

  Widget _bigButton({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onDown,
    VoidCallback? onUp,
  }) {
    return Listener(
      onPointerDown: onDown == null ? null : (_) => onDown(),
      onPointerUp: onUp == null ? null : (_) => onUp(),
      onPointerCancel: onUp == null ? null : (_) => onUp(),
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: onDown == null ? Colors.white12 : color,
          borderRadius: BorderRadius.circular(36),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: _bg, size: 30),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(color: _bg, fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _activationView() {
    final code = klaus.activationCode ?? '------';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        _face(size: 180),
        const SizedBox(height: 12),
        Text('Vamos ativar o ${klaus.lang.agentName} ${klaus.lang.flag}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text(
          '1. Abra o painel do XiaoZhi\n'
          '2. No agente "${klaus.lang.agentName}", toque em "Add Device"\n'
          '3. Escreva este código:',
          style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: code));
            _toast('Código copiado');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
            child: Text(code,
                style: const TextStyle(
                    color: _cyan, fontSize: 40, letterSpacing: 8, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 6),
        const Text('(toque no código para copiar)', style: TextStyle(color: Colors.white38)),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Abrir painel do XiaoZhi'),
          onPressed: () => launchUrl(Uri.parse(KlausConfig.consoleUrl),
              mode: LaunchMode.externalApplication),
        ),
        const SizedBox(height: 10),
        TextButton(onPressed: klaus.start, child: const Text('Tentar de novo')),
        if (klaus.lang.code != 'pt')
          TextButton(
            onPressed: () => klaus.switchLanguage('pt'),
            child: const Text('Voltar ao Klaus em português'),
          ),
        const SizedBox(height: 10),
        const Text('Depois de introduzir o código, o Klaus liga-se sozinho em alguns segundos.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white38)),
      ]),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _face(size: 180),
          const SizedBox(height: 16),
          Text(klaus.errorText ?? 'Erro desconhecido',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 16),
          FilledButton(onPressed: klaus.start, child: const Text('Tentar de novo')),
        ]),
      ),
    );
  }

  void _openMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.system_update, color: _cyan),
            title: const Text('Procurar atualização', style: TextStyle(color: Colors.white)),
            subtitle: Text('Versão instalada: ${KlausConfig.buildNumber} · ouvido: ${klaus.wake.engine}',
                style: const TextStyle(color: Colors.white54)),
            onTap: () {
              Navigator.pop(ctx);
              _checkUpdate();
            },
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize, color: _cyan),
            title: const Text('Painel do XiaoZhi (personalidade)',
                style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(KlausConfig.consoleUrl), mode: LaunchMode.externalApplication);
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh, color: _cyan),
            title: const Text('Religar', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              klaus.start();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: Colors.white54),
            title: const Text('Identificação deste aparelho',
                style: TextStyle(color: Colors.white)),
            subtitle: Text(klaus.identity?.deviceId ?? '-',
                style: const TextStyle(color: Colors.white54)),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: _pink),
            title: const Text('Reiniciar ativação (aparelho novo)',
                style: TextStyle(color: Colors.white)),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Reiniciar ativação?'),
                  content: const Text(
                      'O telemóvel passa a ser um aparelho novo e vai precisar de outro código.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reiniciar')),
                  ],
                ),
              );
              if (ok == true) klaus.resetIdentity();
            },
          ),
        ]),
      ),
    );
  }
}
