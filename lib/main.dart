import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/home_page.dart';
import 'services/app_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 与 Windows 均由 media_kit 系列库提供 libmpv 原生后端。
  MediaKit.ensureInitialized();
  // 桌面端播放页全屏切换需要 window_manager；移动端本就全屏，不初始化。
  if (!Platform.isAndroid && !Platform.isIOS) {
    await windowManager.ensureInitialized();
  }
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
        // 全局使用 MiSans（中文为主），Material 3 各字重由 assets/fonts 四档覆盖。
        fontFamily: 'MiSans',
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
