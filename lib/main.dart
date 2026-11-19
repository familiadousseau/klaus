import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initOpus(await opus_flutter.load());
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  try {
    await WakelockPlus.enable(); // ecrã sempre ligado enquanto o Klaus está aberto
  } catch (_) {}
  runApp(const KlausApp());
}

class KlausApp extends StatelessWidget {
  const KlausApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Klaus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5AE6FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
