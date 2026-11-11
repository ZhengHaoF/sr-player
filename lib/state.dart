import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'services/app_store.dart';

/// SR 档位全局状态：播放器页与设置页共享。
class SrModeController extends Notifier<SrMode> {
  @override
  SrMode build() => AppStore.srMode;

  Future<void> set(SrMode mode) async {
    await AppStore.setSrMode(mode);
    state = mode;
  }
}

final srModeProvider =
    NotifierProvider<SrModeController, SrMode>(SrModeController.new);

/// 目录树当前路径：文件页与"收藏跳转"共享。
class CurrentPathController extends Notifier<String> {
  @override
  String build() => '/storage/emulated/0';

  void set(String path) => state = path;
}

final currentPathProvider =
    NotifierProvider<CurrentPathController, String>(CurrentPathController.new);
