import 'package:dio/dio.dart';

import 'baidu_auth.dart';
import 'baidu_config.dart';

/// 云端文件条目。
class CloudEntry {
  final int fsId;
  final String path; // 云盘绝对路径
  final String name;
  final bool isDir;
  final int size;
  final int category; // 1 视频 / 2 音频 / 3 图片 / 4 文档 / 5 应用 / 6 其他 / 7 种子
  final int modifiedSec;

  /// 缩略图直链（search web=1 / filemetas 提供，可空；8h 签名有效期）。
  final String? thumbUrl;

  const CloudEntry({
    required this.fsId,
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.category,
    required this.modifiedSec,
    this.thumbUrl,
  });

  bool get isVideo => !isDir && category == 1;

  String get sizeLabel {
    if (size <= 0) return '';
    final mb = size / 1048576;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// 云盘 API 异常：errno/message 来源于百度响应。
class BaiduApiException implements Exception {
  final int errno;
  final String message;
  BaiduApiException(this.errno, this.message);
  @override
  String toString() => '百度接口错误 $errno: $message';
}

/// xpan REST 接口封装（调用细节见 docs/网盘在线播放评估.md 附录 A）。
/// 所有调用前自动确保 token 有效；errno != 0 抛 BaiduApiException。
class BaiduApi {
  BaiduApi._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'User-Agent': BaiduConfig.apiUserAgent},
    validateStatus: (code) => code != null && code < 500,
  ));

  /// 统一 GET：query 附 access_token；返回解析后的 JSON（非 JSON 视为端点错误）。
  static Future<Map<String, dynamic>> _get(
    String path, {
    String method = '',
    Map<String, dynamic>? query,
    ResponseType responseType = ResponseType.json,
  }) async {
    if (!await BaiduAuth.ensureValid()) {
      throw BaiduApiException(-1, '未登录或登录已过期');
    }
    final qp = <String, dynamic>{'access_token': BaiduAuth.accessToken};
    if (method.isNotEmpty) qp['method'] = method;
    qp.addAll(query ?? const {});
    try {
      final r = await _dio.get('https://pan.baidu.com/rest/2.0/xpan/$path',
          queryParameters: qp,
          options: Options(responseType: responseType));
      if (responseType == ResponseType.json) {
        final data = r.data;
        if (data is! Map<String, dynamic>) {
          throw BaiduApiException(-2, '接口返回异常（非 JSON），请检查端点/参数');
        }
        final errno = (data['errno'] as num?)?.toInt();
        if (errno != null && errno != 0) {
          throw BaiduApiException(errno,
              (data['errmsg'] as String?) ?? (data['show_msg'] as String?) ?? '未知错误');
        }
        return data;
      }
      // plain（m3u8 校验用）。
      final text = r.data as String;
      if (!text.trimLeft().startsWith('#EXTM3U')) {
        // 尝试解析 errno（streaming 失败会返回 JSON 错误体）。
        final errno = RegExp(r'"errno":\s*(-?\d+)').firstMatch(text)?.group(1);
        throw BaiduApiException(
            int.tryParse(errno ?? '') ?? -3, '云端转码流不可用: ${text.length > 120 ? text.substring(0, 120) : text}');
      }
      return {'m3u8': text};
    } on DioException catch (e) {
      throw BaiduApiException(-4, '网络请求失败: ${e.message}');
    }
  }

  /// 目录列表。order: name/time/size；返回 (条目, 是否还有更多)。
  static Future<(List<CloudEntry>, bool)> list(
    String dir, {
    int start = 0,
    int limit = 100,
    String order = 'name',
    bool desc = false,
  }) async {
    final data = await _get('file', method: 'list', query: {
      'dir': dir,
      'web': 1,
      'start': start,
      'limit': limit,
      'order': order,
      'desc': desc ? 1 : 0,
    });
    final entries = _parseEntries(data['list'] as List?);
    final hasMore = entries.length >= limit && start + entries.length < ((data['total'] as num?)?.toInt() ?? start + entries.length);
    return (entries, hasMore);
  }

  /// list[] 同构条目解析：method=list 与 method=search 共用。
  /// thumbs 四档任取大图（url3>url2>url1>icon），与网盘页逻辑一致。
  static List<CloudEntry> _parseEntries(List? raw) {
    return (raw ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) {
          final thumbs = m['thumbs'];
          String? thumb;
          if (thumbs is Map) {
            thumb =
                (thumbs['url3'] ?? thumbs['url2'] ?? thumbs['url1'] ??
                thumbs['icon']) as String?;
            if (thumb != null && thumb.isEmpty) thumb = null;
          }
          return CloudEntry(
            fsId: (m['fs_id'] as num?)?.toInt() ?? 0,
            path: (m['path'] as String?) ?? '',
            name: (m['server_filename'] as String?) ?? '',
            isDir: (m['isdir'] as num?)?.toInt() == 1,
            size: (m['size'] as num?)?.toInt() ?? 0,
            category: (m['category'] as num?)?.toInt() ?? 6,
            modifiedSec: (m['server_mtime'] as num?)?.toInt() ?? 0,
            thumbUrl: thumb,
          );
        })
        .toList();
  }

  /// 关键词搜索（手册 A.7；2026-11-15 探针实测权限通过）。
  /// key ≤ 30 个 UTF-8 字符（接口限制，UI 侧限制输入长度）。
  /// category=1 只搜视频；recursion=1 全盘递归；web=1 响应直带缩略图。
  /// 返回 (条目, has_more)。接口无 start/cursor 翻页参数，单页上限 500。
  static Future<(List<CloudEntry>, bool)> search(
    String key, {
    String dir = '/',
    int category = 1,
    bool recursion = true,
  }) async {
    final data = await _get('file', method: 'search', query: {
      'key': key,
      'dir': dir,
      'category': category,
      'num': 500,
      if (recursion) 'recursion': 1,
      'web': 1,
    });
    final hasMore = (data['has_more'] as num?)?.toInt() == 1;
    return (_parseEntries(data['list'] as List?), hasMore);
  }

  /// 批量文件元信息（≤100 个 fsid）。返回 fsid → info 映射。
  static Future<Map<int, Map<String, dynamic>>> filemetas(
    List<int> fsids, {
    bool dlink = false,
    bool thumb = false,
    bool extra = false,
  }) async {
    if (fsids.isEmpty) return {};
    final data = await _get('file', method: 'filemetas', query: {
      'fsids': jsonEncodeList(fsids),
      'dlink': dlink ? 1 : 0,
      'thumb': thumb ? 1 : 0,
      'extra': extra ? 1 : 0,
    });
    final out = <int, Map<String, dynamic>>{};
    for (final m in ((data['info'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()) {
      final id = (m['fs_id'] as num?)?.toInt() ?? 0;
      if (id > 0) out[id] = m;
    }
    return out;
  }

  static String jsonEncodeList(List<int> ids) =>
      '[${ids.join(',')}]';

  /// 场景切分点（秒）：filemetas(extra=1) 的 scene_info，如 "[0,20,31,...]"
  /// （手册 A.9）。用于播放页进度条章节标记 + 场景跳转。
  /// 无数据/解析失败返回空表（调用方静默处理）。
  static Future<List<int>> sceneInfo(int fsId) async {
    final data = await _get('file', method: 'filemetas', query: {
      'fsids': jsonEncodeList([fsId]),
      'extra': 1,
    });
    final info =
        (data['info'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const <Map<String, dynamic>>[];
    if (info.isEmpty) return const [];
    final raw = info.first['scene_info'];
    if (raw is List) {
      return raw.whereType<num>().map((n) => n.toInt()).toList()..sort();
    }
    if (raw is String && raw.isNotEmpty) {
      // 实测是 JSON 数组字符串，容错直接抽数字序列。
      return RegExp(r'\d+')
          .allMatches(raw)
          .map((m) => int.parse(m.group(0)!))
          .toList()
        ..sort();
    }
    return const [];
  }

  /// 容量信息（已用/总量，字节）。走实测可用的 web 风格端点。
  static Future<(int used, int total)> quota() async {
    if (!await BaiduAuth.ensureValid()) {
      throw BaiduApiException(-1, '未登录或登录已过期');
    }
    final qp = {'checkfree': 1, 'checkunfree': 1, 'access_token': BaiduAuth.accessToken};
    try {
      final r = await _dio.get<Map<String, dynamic>>(
          'https://pan.baidu.com/api/quota', queryParameters: qp);
      final data = r.data;
      if (data == null || (data['errno'] as num?)?.toInt() != 0) {
        throw BaiduApiException(-2, '容量查询失败');
      }
      final total = (data['total'] as num?)?.toInt() ?? 0;
      final free = (data['free'] as num?)?.toInt() ?? 0;
      return (total - free, total);
    } on DioException catch (e) {
      throw BaiduApiException(-4, '网络请求失败: ${e.message}');
    }
  }

  /// 云端转码 m3u8 播放地址（直接可作为 mpv 输入 URL）。
  /// 返回前用 plain GET 预检响应确为 m3u8（转码不可用时抛 BaiduApiException）。
  static Future<String> streamingUrl(String cloudPath, String type) async {
    final qp = {
      'method': 'streaming',
      'access_token': BaiduAuth.accessToken,
      'path': cloudPath,
      'type': type,
    };
    const base = 'https://pan.baidu.com/rest/2.0/xpan/multimedia';
    // 预检：确认转码流可用（响应为 m3u8 文本）。
    await _get('multimedia', method: 'streaming',
        query: {'path': cloudPath, 'type': type},
        responseType: ResponseType.plain);
    return '$base?${Uri(queryParameters: qp).query}';
  }

  /// 下载直链 dlink（8h 过期）。需要 fsid。
  static Future<String> dlink(int fsId) async {
    final metas = await filemetas([fsId], dlink: true);
    final d = metas[fsId]?['dlink'] as String?;
    if (d == null || d.isEmpty) throw BaiduApiException(-3, '未取得下载直链');
    return '$d&access_token=${BaiduAuth.accessToken}';
  }

  /// 通过父目录列表反查 fsid（dlink 需要 fsid；历史记录续播场景只有路径）。
  static Future<int> resolveFsid(String cloudPath) async {
    final slash = cloudPath.lastIndexOf('/');
    final parent = slash <= 0 ? '/' : cloudPath.substring(0, slash);
    final name = slash < 0 ? cloudPath : cloudPath.substring(slash + 1);
    var start = 0;
    while (true) {
      final (entries, hasMore) = await list(parent, start: start, limit: 1000);
      for (final e in entries) {
        if (!e.isDir && e.path == cloudPath) return e.fsId;
        if (e.name == name && !e.isDir) return e.fsId;
      }
      if (!hasMore || entries.isEmpty) break;
      start += entries.length;
    }
    throw BaiduApiException(-9, '云端文件不存在: $cloudPath');
  }

  /// 用户信息（登录验证用）。
  static Future<String> netdiskName() async {
    final data = await _get('nas', method: 'uinfo');
    return (data['netdisk_name'] as String?) ?? '';
  }
}
