import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'app_store.dart';
import 'media_store.dart';

/// 文件系统浏览辅助：列目录、排序、缩略图缓存。
class FsService {
  FsService._();

  /// 列出目录内容：隐藏文件按设置过滤，文件夹在前、各按名称排序。
  static Future<List<FileSystemEntity>> listDir(String path) async {
    final dir = Directory(path);
    final entries = await dir.list(followLinks: false).toList();
    final showHidden = AppStore.showHidden;

    final visible = entries.where((e) {
      final name = fileNameOf(e.path);
      if (!showHidden && name.startsWith('.')) return false;
      return true;
    }).toList();

    int rank(FileSystemEntity e) =>
        e is Directory ? 0 : (isVideoPath(e.path) ? 1 : 2);

    visible.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return fileNameOf(a.path).toLowerCase().compareTo(fileNameOf(b.path).toLowerCase());
    });
    return visible;
  }

  static String fileNameOf(String path) {
    final i = path.lastIndexOf('/');
    return i >= 0 && i < path.length - 1 ? path.substring(i + 1) : path;
  }

  static String parentOf(String path) {
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    final i = path.lastIndexOf('/');
    return i > 0 ? path.substring(0, i) : path;
  }

  /// 面包屑：把绝对路径拆成 (名称, 到该级的完整路径) 列表。
  /// [root] 非空时，只展示主存储根目录及其子级（不再展示 /storage、
  /// /storage/emulated 等无权限的上级路径，防止误入）。
  static List<(String, String)> breadcrumbs(String path, {String? root}) {
    final result = <(String, String)>[];
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final parts = normalized.split('/')..removeWhere((s) => s.isEmpty);
    var acc = '';
    for (final part in parts) {
      acc = '$acc/$part';
      if (root == null || root.isEmpty) {
        result.add((part, acc));
      } else if (acc == root || acc.startsWith('$root/')) {
        result.add((part, acc));
      }
    }
    return result;
  }

  /// 主存储根目录。
  static Future<String> storageRoot() async {
    // Android 主存储固定路径；用目录存在性兜底。
    const candidates = ['/storage/emulated/0', '/sdcard'];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return (await getApplicationDocumentsDirectory()).path;
  }
}

/// 视频缩略图缓存：路径 → JPEG 字节（走平台通道，内存缓存带上限）。
/// 取图不直接发起，而是进入有限并发的任务队列：进入文件夹/快速滚动时
/// 不会一次性压几十个原生抽帧任务；tile 已销毁的任务在开跑前直接跳过。
class ThumbCache {
  ThumbCache._();

  static const int _cap = 400;

  /// 同时进行的原生取图任务数，其余按进入顺序排队。
  static const int _maxInFlight = 2;

  static final Map<String, Uint8List?> _cache = {};
  static final List<_ThumbTask> _queue = [];
  static final Map<String, _ThumbTask> _pending = {};
  static int _inFlight = 0;

  static Uint8List? getSync(String path) => _cache[path];

  static Future<Uint8List?> get(
    String path, {
    String? contentUri,
    bool Function()? isCancelled,
  }) {
    if (_cache.containsKey(path)) return Future.value(_cache[path]);
    // 同一路径已有任务在排队/执行：直接复用其结果。
    final pending = _pending[path];
    if (pending != null) return pending.completer.future;
    final task = _ThumbTask(path, contentUri, isCancelled);
    _pending[path] = task;
    _queue.add(task);
    _pump();
    return task.completer.future;
  }

  static void _pump() {
    while (_inFlight < _maxInFlight && _queue.isNotEmpty) {
      _run(_queue.removeAt(0));
    }
  }

  static Future<void> _run(_ThumbTask task) async {
    _inFlight++;
    Uint8List? bytes;
    // tile 已随滚动销毁：跳过原生抽帧，也不把"没取到"写进缓存。
    final cancelled = task.isCancelled?.call() ?? false;
    if (!cancelled) {
      bytes = await MediaStoreService.thumbnail(path: task.path, contentUri: task.contentUri);
    }
    _inFlight--;
    _pending.remove(task.path);
    if (!cancelled) {
      if (_cache.length >= _cap) _cache.remove(_cache.keys.first);
      _cache[task.path] = bytes;
    }
    task.completer.complete(bytes);
    _pump();
  }

  static void clearMemory() {
    _cache.clear();
    // 未开跑的任务直接作废，避免清缓存后又冒出旧图。
    for (final task in _queue) {
      _pending.remove(task.path);
      task.completer.complete(null);
    }
    _queue.clear();
  }
}

/// 队列中的一个取图任务。[isCancelled] 由发起方（tile）在销毁时置真。
class _ThumbTask {
  final String path;
  final String? contentUri;
  final bool Function()? isCancelled;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();

  _ThumbTask(this.path, this.contentUri, this.isCancelled);
}
