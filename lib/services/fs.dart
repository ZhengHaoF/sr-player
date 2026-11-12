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
class ThumbCache {
  ThumbCache._();

  static const int _cap = 400;
  static final Map<String, Uint8List?> _cache = {};

  static Uint8List? getSync(String path) => _cache[path];

  static Future<Uint8List?> get(String path, {String? contentUri}) async {
    if (_cache.containsKey(path)) return _cache[path];
    final bytes = await MediaStoreService.thumbnail(path: path, contentUri: contentUri);
    if (_cache.length >= _cap) _cache.remove(_cache.keys.first);
    _cache[path] = bytes;
    return bytes;
  }

  static void clearMemory() => _cache.clear();
}
