/// 数据模型与通用工具。
library;

/// 超分辨率档位。
enum SrMode { off, performance, quality, experimental }

extension SrModeLabel on SrMode {
  String get label => switch (this) {
        SrMode.off => '关闭',
        SrMode.performance => '性能',
        SrMode.quality => '质量',
        SrMode.experimental => '实验',
      };

  String get desc => switch (this) {
        SrMode.off => '不挂载任何着色器，功耗最低。',
        SrMode.performance =>
          'Anime4K CNN S/M 档，兼顾流畅与画质，大多数设备推荐。',
        SrMode.quality =>
          'Anime4K CNN VL 档，画质最佳，对 GPU 要求较高，卡顿请切回性能档。',
        SrMode.experimental =>
          'ArtCNN C4F32 DS（需含 gpu-next 的自编译内核），当前预编译内核不可用。',
      };
}

/// 一个本地视频条目（来自 MediaStore 或文件浏览）。
class VideoItem {
  final String path;
  final String name;
  final int durationMs;
  final int sizeBytes;
  final int modifiedSec;
  final int width;
  final int height;

  /// MediaStore 内容 URI（仅媒体库条目有，用于快速取缩略图）。
  final String contentUri;

  const VideoItem({
    required this.path,
    required this.name,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.modifiedSec = 0,
    this.width = 0,
    this.height = 0,
    this.contentUri = '',
  });

  factory VideoItem.fromMap(Map<Object?, Object?> m) => VideoItem(
        path: (m['path'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedSec: (m['modifiedSec'] as num?)?.toInt() ?? 0,
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        contentUri: (m['contentUri'] as String?) ?? '',
      );

  /// 所在目录（不含末尾斜杠）。
  String get folder {
    final i = path.lastIndexOf('/');
    return i > 0 ? path.substring(0, i) : '/';
  }

  String get durationLabel {
    final s = durationMs ~/ 1000;
    if (s <= 0) return '--:--';
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  String get sizeLabel {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / 1048576;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  DateTime get modifiedDate =>
      DateTime.fromMillisecondsSinceEpoch(modifiedSec * 1000);
}

/// 支持的视频扩展名。
const videoExtensions = {
  'mp4', 'mkv', 'avi', 'mov', 'flv', 'ts', 'webm', 'wmv', 'm4v', '3gp',
  'mpg', 'mpeg', 'rmvb', 'vob', 'm2ts', 'ogv',
};

bool isVideoPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return videoExtensions.contains(path.substring(dot + 1).toLowerCase());
}
