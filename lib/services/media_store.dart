import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models.dart';

/// 通过平台通道读取 MediaStore 视频库与缩略图（Android 原生实现见 MainActivity.kt）。
class MediaStoreService {
  MediaStoreService._();

  static const MethodChannel _channel = MethodChannel('sr_player/media');

  /// 扫描全部本地视频，按修改时间倒序。失败时返回空列表。
  static Future<List<VideoItem>> listVideos() async {
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
}
