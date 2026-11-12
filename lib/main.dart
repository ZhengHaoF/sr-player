import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/home_page.dart';
import 'services/app_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 与 Windows 均由 media_kit 系列库提供 libmpv 原生后端。
  MediaKit.ensureInitialized();
  await AppStore.init();
  runApp(const ProviderScope(child: SrPlayerApp()));
}

class SrPlayerApp extends StatelessWidget {
  const SrPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SR Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
