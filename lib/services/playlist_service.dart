import 'dart:io';

import '../models.dart' show videoExtensions;
import 'app_store.dart';
import 'fs.dart';
import 'netdisk/baidu_api.dart';
import 'netdisk/play_source.dart';

/// 播放列表条目：可播放源 + 显示标题 + 从文件名识别的集数（可空）。
class PlaylistEntry {
  final PlayableSource source;
  final String title;
  final int? episode;

  const PlaylistEntry({
    required this.source,
    required this.title,
    this.episode,
  });

  /// 断点续播状态：'已看完' / '看到 mm:ss'，无记录返回 null。
  String? get resumeLabel {
    final saved = AppStore.getPosition(source.resumeKey);
    final pos = (saved?['pos'] as num?)?.toInt() ?? 0;
    final dur = (saved?['dur'] as num?)?.toInt() ?? 0;
    if (pos <= 0) return null;
    if (dur > 0 && pos >= dur * 0.95) return '已看完';
    final s = pos ~/ 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    final mm = (s % 3600) ~/ 60, ss = s % 60;
    return '看到 ${two(mm)}:${two(ss)}';
  }
}

/// 播放列表发现：由当前播放源定位其同目录（本地父目录 / 网盘同目录），
/// 过滤视频文件并按集数排序。入口页零改动，播放页自行调用。
class PlaylistService {
  PlaylistService._();

  /// 集数识别，五类命名按最左命中：
  /// `第xx集/话`、`SxxEyy`、`EPxx`/`Exx`、分隔符后的数字（` - 05 [720p].mkv`）、
  /// 扩展名前的结尾数字（`05.mkv`）。分辨率数字（1080p 等）通过前瞻排除。
  static final RegExp _epPattern = RegExp(
    r'第\s*(\d{1,4})\s*[集话話]'
    r'|S\d{1,3}E(\d{1,4})(?!\d)'
    r'|\bEP?\.?\s*(\d{1,4})(?!\d|[pPkK])'
    r'|(?:^|[\s\-_.])(\d{1,4})(?!\d|[pPkK])(?=[\s]*(?:\[[^\]]+\])?[^.]*\.[^.]+$)'
    r'|(\d{1,4})(?=\.[^.]*$)',
    caseSensitive: false,
  );

  static int? episodeNumberOf(String name) {
    final m = _epPattern.firstMatch(name);
    if (m == null) return null;
    for (final g in m.groups([1, 2, 3, 4, 5])) {
      if (g != null) return int.tryParse(g);
    }
    return null;
  }

  /// 自然排序：数字段按数值比较（055 == 55）。
  static int naturalCompare(String a, String b) {
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final da = _isDigit(a[i]), db = _isDigit(b[j]);
      if (da && db) {
        final si = i, sj = j;
        while (i < a.length && _isDigit(a[i])) {
          i++;
        }
        while (j < b.length && _isDigit(b[j])) {
          j++;
        }
        final na = int.tryParse(a.substring(si, i)) ?? 0;
        final nb = int.tryParse(b.substring(sj, j)) ?? 0;
        if (na != nb) return na.compareTo(nb);
      } else {
        if (a[i] != b[j]) return a[i].compareTo(b[j]);
        i++;
        j++;
      }
    }
    return (a.length - i).compareTo(b.length - j);
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  /// 统一入口：按源类型发现同目录播放列表（已排序）。
  static Future<List<PlaylistEntry>> discover(PlayableSource source) async {
    if (source is LocalPlayableSource) return _discoverLocal(source);
    if (source is BaiduPlayableSource) return _discoverBaidu(source);
    return const [];
  }

  static Future<List<PlaylistEntry>> _discoverLocal(
    LocalPlayableSource current,
  ) async {
    final dir = FsService.parentOf(FsService.normalizePath(current.path));
    final List<FileSystemEntity> entities;
    try {
      entities = await FsService.listDir(dir);
    } catch (_) {
      return const []; // 目录不可读：静默放弃列表
    }
    final entries = <PlaylistEntry>[];
    for (final e in entities) {
      if (e is! File) continue;
      final name = FsService.fileNameOf(e.path);
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!videoExtensions.contains(ext)) continue;
      entries.add(
        PlaylistEntry(
          source: LocalPlayableSource(path: e.path, title: name),
          title: name,
          episode: episodeNumberOf(name),
        ),
      );
    }
    return _sort(entries);
  }

  static Future<List<PlaylistEntry>> _discoverBaidu(
    BaiduPlayableSource current,
  ) async {
    final path = FsService.normalizePath(current.cloudPath);
    final i = path.lastIndexOf('/');
    final dir = i > 0 ? path.substring(0, i) : '/';
    // 分页拉全目录（153 集量级 2 页内完成）。
    final entries = <PlaylistEntry>[];
    var start = 0;
    while (true) {
      final (page, hasMore) = await BaiduApi.list(
        dir,
        start: start,
        limit: 100,
      );
      for (final e in page) {
        if (!e.isVideo) continue;
        entries.add(
          PlaylistEntry(
            source: BaiduPlayableSource(
              cloudPath: e.path,
              title: e.name,
              fsId: e.fsId,
            ),
            title: e.name,
            episode: episodeNumberOf(e.name),
          ),
        );
      }
      if (!hasMore || page.isEmpty) break;
      start += page.length;
    }
    return _sort(entries);
  }

  /// 排序：有集数按集数升序在前，无集数按自然序排其后；同集数自然序兜底。
  static List<PlaylistEntry> _sort(List<PlaylistEntry> entries) {
    int cmp(PlaylistEntry a, PlaylistEntry b) {
      final ea = a.episode, eb = b.episode;
      if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
      if (ea != null && eb == null) return -1;
      if (ea == null && eb != null) return 1;
      return naturalCompare(a.title, b.title);
    }

    entries.sort(cmp);
    return entries;
  }

  /// 按源 resumeKey 定位当前条目下标；不存在返回 -1。
  static int indexOf(List<PlaylistEntry> entries, String resumeKey) =>
      entries.indexWhere((e) => e.source.resumeKey == resumeKey);
}
