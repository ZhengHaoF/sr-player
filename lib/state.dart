import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'services/app_store.dart';
import 'services/fs.dart';

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

/// 主存储根目录（异步确认；加载完成前用常见路径兜底）。
final storageRootProvider = FutureProvider<String>((ref) {
  return FsService.storageRoot();
});

/// 首页当前 Tab：文件页据此判断返回手势是否应由自己处理。
class CurrentTabController extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) => state = index;
}

final currentTabProvider =
    NotifierProvider<CurrentTabController, int>(CurrentTabController.new);
