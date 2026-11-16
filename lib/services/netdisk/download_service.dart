import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../app_store.dart';
import 'baidu_api.dart';
import 'baidu_config.dart';

/// 下载任务状态。
enum DownloadStatus { queued, running, paused, done, failed }

/// 一个网盘文件下载任务（id = 云盘绝对路径，天然去重键）。
class DownloadTask {
  final String id;
  final int fsId;
  final String cloudPath;
  final String name;
  int totalBytes;
  int receivedBytes;
  DownloadStatus status;
  String? localPath; // 完成后的本地文件路径
  String? error;

  DownloadTask({
    required this.id,
    required this.fsId,
    required this.cloudPath,
    required this.name,
    required this.totalBytes,
    this.receivedBytes = 0,
    this.status = DownloadStatus.queued,
    this.localPath,
    this.error,
  });

  bool get isFinished => status == DownloadStatus.done;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fsId': fsId,
        'cloudPath': cloudPath,
        'name': name,
        'total': totalBytes,
        'received': receivedBytes,
        'status': status.index,
        'localPath': localPath,
        'error': error,
      };

  static DownloadTask fromJson(Map<String, dynamic> m) => DownloadTask(
        id: m['id'] as String,
        fsId: (m['fsId'] as num?)?.toInt() ?? 0,
        cloudPath: m['cloudPath'] as String,
        name: m['name'] as String,
        totalBytes: (m['total'] as num?)?.toInt() ?? 0,
        receivedBytes: (m['received'] as num?)?.toInt() ?? 0,
        status: DownloadStatus.values[(m['status'] as num?)?.toInt() ?? 0],
        localPath: m['localPath'] as String?,
        error: m['error'] as String?,
      );
}

/// 网盘下载服务（单例 ChangeNotifier）。
/// 串行队列；Range 断点续传（.part 半成品文件）；网络中断自动换新直链重试；
/// 完成后把云端续播进度迁移到本地文件（baidu://<路径> → 本地路径，附录 A.8）。
/// 任务列表持久化在 AppStore，重启后 running/queued 落回 paused 可续传。
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final instance = DownloadService._();

  static const _storeKey = 'netdisk_downloads';

  Directory? _dir; // 下载目录缓存

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    // 流式下载不设接收超时：限速账号下大文件分片间隔可能很长。
    headers: {'User-Agent': BaiduConfig.downloadUserAgent},
    validateStatus: (code) => code != null && code < 500,
  ));

  final List<DownloadTask> _tasks = [];
  CancelToken? _cancelToken;
  bool _running = false;
  bool _initialized = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  Future<Directory> _downloadDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    // Android：app 私有外存目录，免存储权限；桌面端退回应用支持目录。
    final base = await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    final dir =
        Directory('${base.path}${Platform.pathSeparator}netdisk_downloads');
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// 文件名安全化：替换路径分隔符/非法字符，超长时保留扩展名截断。
  static String _safeName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    if (s.length > 120) {
      final dot = s.lastIndexOf('.');
      s = dot > 0 && dot > s.length - 12
          ? s.substring(0, 120 - (s.length - dot)) + s.substring(dot)
          : s.substring(0, 120);
    }
    return s.isEmpty ? 'unnamed' : s;
  }

  /// 启动/首次使用时恢复任务列表。
  Future<void> ensureLoaded() async {
    if (_initialized) return;
    _initialized = true;
    final raw = AppStore.getString(_storeKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list =
            (jsonDecode(raw) as List).whereType<Map<String, dynamic>>();
        for (final m in list) {
          final t = DownloadTask.fromJson(m);
          if (t.status == DownloadStatus.running ||
              t.status == DownloadStatus.queued) {
            t.status = DownloadStatus.paused; // 进程被杀：落回暂停，可续传
          }
          if (t.status == DownloadStatus.done &&
              t.localPath != null &&
              !await File(t.localPath!).exists()) {
            t.status = DownloadStatus.failed;
            t.error = '本地文件已被清理，可重新下载';
          }
          _tasks.add(t);
        }
      } catch (e) {
        debugPrint('[download] 任务记录损坏，忽略: $e');
      }
    }
    _notify(force: true);
  }

  DownloadTask? _byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 已存在同云盘路径的任务（失败态除外）视为重复。
  bool contains(String cloudPath) {
    for (final t in _tasks) {
      if (t.cloudPath == cloudPath && t.status != DownloadStatus.failed) {
        return true;
      }
    }
    return false;
  }

  /// 加入队列。返回 false 表示已存在重复任务。
  Future<bool> add({
    required int fsId,
    required String cloudPath,
    required String name,
    required int size,
  }) async {
    await ensureLoaded();
    if (contains(cloudPath)) return false;
    _tasks.insert(
      0,
      DownloadTask(
        id: cloudPath,
        fsId: fsId,
        cloudPath: cloudPath,
        name: name,
        totalBytes: size,
      ),
    );
    _persist();
    _notify(force: true);
    unawaited(_pump());
    return true;
  }

  /// 暂停（运行中的任务取消请求，保留 .part 半成品）。
  void pause(String id) {
    final t = _byId(id);
    if (t == null) return;
    if (t.status == DownloadStatus.running) {
      _cancelToken?.cancel('已暂停');
    } else if (t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.paused;
      _persist();
      _notify(force: true);
    }
  }

  /// 暂停续传 / 失败重试。
  void resume(String id) {
    final t = _byId(id);
    if (t == null) return;
    if (t.status == DownloadStatus.paused ||
        t.status == DownloadStatus.failed) {
      t.status = DownloadStatus.queued;
      t.error = null;
      _persist();
      _notify(force: true);
      unawaited(_pump());
    }
  }

  /// 删除任务与本地文件（含 .part 半成品）。运行中先取消请求。
  Future<void> remove(String id) async {
    final t = _byId(id);
    if (t == null) return;
    if (t.status == DownloadStatus.running) {
      _cancelToken?.cancel('删除任务');
    }
    try {
      final dir = await _downloadDir();
      final safe = _safeName(t.name);
      for (final suffix in ['', '.part']) {
        final f = File('${dir.path}${Platform.pathSeparator}$safe$suffix');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {
      // 文件清理失败不阻塞记录删除
    }
    _tasks.remove(t);
    _persist();
    _notify(force: true);
  }

  /// 队列泵：串行执行 queued 任务。
  Future<void> _pump() async {
    if (_running) return;
    DownloadTask? next;
    for (final t in _tasks) {
      if (t.status == DownloadStatus.queued) {
        next = t;
        break;
      }
    }
    if (next == null) return;
    _running = true;
    try {
      await _run(next);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        next.status = DownloadStatus.paused; // 暂停/删除：保留半成品可续传
      } else {
        next.status = DownloadStatus.failed;
        next.error = '网络错误：${e.message}';
      }
    } on BaiduApiException catch (e) {
      next.status = DownloadStatus.failed;
      next.error = '$e';
    } catch (e) {
      next.status = DownloadStatus.failed;
      next.error = '$e';
    } finally {
      _cancelToken = null;
      _running = false;
      _persist();
      _notify(force: true);
    }
    unawaited(_pump()); // 还有排队的继续
  }

  /// 执行单个任务：断点续传 + 网络中断自动换新直链重试一次。
  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.running;
    task.error = null;
    _notify(force: true);

    final dir = await _downloadDir();
    final safe = _safeName(task.name);
    final part = File('${dir.path}${Platform.pathSeparator}$safe.part');
    final dest = File('${dir.path}${Platform.pathSeparator}$safe');
    var startBytes = (await part.exists()) ? await part.length() : 0;
    if (task.totalBytes > 0 && startBytes > task.totalBytes) {
      await part.delete(); // 记录与半成品不一致：从头下
      startBytes = 0;
    }

    var retriedLink = false;
    while (true) {
      final dlink = await BaiduApi.dlink(task.fsId); // 每次重取，规避 8h 过期
      _cancelToken = CancelToken();
      final Response<ResponseBody> rsp;
      try {
        rsp = await _dio.get<ResponseBody>(
          dlink,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              if (startBytes > 0) 'Range': 'bytes=$startBytes-',
            },
          ),
          cancelToken: _cancelToken,
        );
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        // 连接重置等瞬时错误：换新直链（新签名）重试一次。
        if (!retriedLink) {
          retriedLink = true;
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        rethrow;
      }
      final status = rsp.statusCode ?? 0;
      if (status == 200 && startBytes > 0) {
        // 服务器不支持 Range（罕见）：删半成品从头下。
        await part.delete();
        startBytes = 0;
      }
      if (status != 200 && status != 206) {
        throw BaiduApiException(-5, '下载响应异常（HTTP $status）');
      }
      final rest = int.tryParse(
              rsp.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
          0;
      task.totalBytes = status == 206 ? startBytes + rest : rest;
      task.receivedBytes = startBytes;
      _notify(force: true);

      final sink = part.openWrite(
          mode: (status == 206 && startBytes > 0)
              ? FileMode.append
              : FileMode.write);
      var received = startBytes;
      var lastFlush = received;
      try {
        await for (final chunk in rsp.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          task.receivedBytes = received;
          // 1MB 一刷：给磁盘写提供背压，避免内存积压；进度通知另行节流。
          if (received - lastFlush >= 1 << 20) {
            lastFlush = received;
            await sink.flush();
          }
          _notify();
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      if (task.totalBytes > 0 && received < task.totalBytes) {
        throw BaiduApiException(
            -6, '连接提前中断（$received/${task.totalBytes}），可续传重试');
      }
      await part.rename(dest.path);
      task.localPath = dest.path;
      task.status = DownloadStatus.done;
      _migrateResume(task);
      _persist();
      _notify(force: true);
      return;
    }
  }

  /// 续播键迁移（附录 A.8）：云端 baidu://{path} 的进度挪到本地文件。
  void _migrateResume(DownloadTask task) {
    if (task.localPath == null) return;
    final saved = AppStore.getPosition('baidu://${task.cloudPath}');
    if (saved == null) return;
    final pos = (saved['pos'] as num?)?.toInt() ?? 0;
    final dur = (saved['dur'] as num?)?.toInt() ?? 0;
    if (pos <= 0) return;
    AppStore.recordPlayback(
      path: task.localPath!,
      name: task.name,
      posMs: pos,
      durMs: dur,
    );
  }

  void _persist() {
    AppStore.setString(
      _storeKey,
      jsonEncode(_tasks.map((t) => t.toJson()).toList()),
    );
  }

  /// 进度通知节流（400ms）；状态变更用 force 立即刷。
  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify).inMilliseconds < 400) return;
    _lastNotify = now;
    notifyListeners();
  }
}
