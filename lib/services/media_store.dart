import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import 'fs.dart';

/// 视频库数据源：
/// - Android：通过平台通道读取 MediaStore 视频库与缩略图（原生实现见 MainActivity.kt）；
/// - Windows（桌面）：退化为文件系统递归扫描，元数据取自文件 stat，
///   时长/分辨率未知（显示 --:--），缩略图走占位图标。
class MediaStoreService {
  MediaStoreService._();

  static const MethodChannel _channel = MethodChannel('sr_player/media');

  /// 桌面扫描深度上限：从根目录最多向下递归的层数。
  static const int _maxDepth = 8;

  /// 桌面扫描条目上限：防止海量目录拖垮首屏（超出即停止，按已扫结果排序）。
  static const int _maxResults = 5000;

  /// 扫描全部本地视频，按修改时间倒序。失败时返回空列表。
  static Future<List<VideoItem>> listVideos() async {
    if (!Platform.isAndroid) return _scanFilesystem();
    try {
      final res = await _channel.invokeListMethod<dynamic>('listVideos');
      if (res == null) return const [];
      return [
        for (final e in res)
          if (e is Map) VideoItem.fromMap(e.cast<Object?, Object?>()),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 取视频缩略图（JPEG 字节）。失败返回 null。
  static Future<Uint8List?> thumbnail({String? path, String? contentUri}) async {
    try {
      final res = await _channel.invokeMethod<List<dynamic>>(
          'thumbnail', {'path': path, 'contentUri': contentUri});
      if (res == null) return null;
      return Uint8List.fromList(res.cast<int>());
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 桌面端视频库：从主存储根目录手动逐层递归扫描视频文件。
  /// 手动递归（而非 Directory.list(recursive:true)）是为了能剪枝：
  /// 跳过隐藏/系统目录（AppData、$Recycle.Bin 等）与符号链接，限深限条目。
  static Future<List<VideoItem>> _scanFilesystem() async {
    final root = FsService.fallbackRoot;
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return const [];

    final results = <VideoItem>[];
    final stack = <(Directory, int)>[(rootDir, 0)];
    while (stack.isNotEmpty && results.length < _maxResults) {
      final (dir, depth) = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        continue; // 无权限/已被移除的目录：跳过，继续扫其余部分。
      }
      for (final e in entries) {
        if (results.length >= _maxResults) break;
        if (e is Directory) {
          final name = FsService.fileNameOf(FsService.normalizePath(e.path));
          if (name.startsWith('.') || FsService.isSystemHiddenName(name)) {
            continue;
          }
          if (depth < _maxDepth) {
            stack.add((Directory(FsService.normalizePath(e.path)), depth + 1));
          }
          continue;
        }
        if (e is! File) continue; // 符号链接等一律不深入，避免环。
        final path = FsService.normalizePath(e.path);
        if (!isVideoPath(path)) continue;
        final st = await e.stat();
        results.add(VideoItem(
          path: path,
          name: FsService.fileNameOf(path),
          sizeBytes: st.size,
          modifiedSec: st.modified.millisecondsSinceEpoch ~/ 1000,
        ));
      }
    }
    results.sort((a, b) => b.modifiedSec.compareTo(a.modifiedSec));
    return results;
  }
}
