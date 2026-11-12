import 'baidu_api.dart';

/// 清晰度选项。key 为空串表示「原画」（dlink 原文件直链）。
class StreamQuality {
  final String key;
  final String label;
  const StreamQuality(this.key, this.label);

  static const originKey = '';
}

/// 一次可打开的媒体流：mpv 输入 URI + HTTP 头。
class PlayStream {
  final String uri;
  final Map<String, String> headers;
  final String qualityKey;

  const PlayStream({
    required this.uri,
    this.headers = const {},
    required this.qualityKey,
  });

  bool get isNetwork => uri.startsWith('http');
}

/// 可播放源抽象：统一本地文件与云盘在线文件，PlayerPage 不感知来源差异。
abstract class PlayableSource {
  String get title;

  /// 续播/历史记录键。本地为文件路径，云盘为 baidu://<云盘路径>。
  String get resumeKey;

  /// 可选清晰度列表；空列表表示无清晰度概念（本地文件）。
  List<StreamQuality> get qualities;

  /// 打开指定清晰度。key 取自 qualities[].key；失败抛异常
  /// （云盘转码不可用时抛 BaiduApiException，由播放页自动降级原画）。
  Future<PlayStream> open(String qualityKey);
}

/// 本地文件源。
class LocalPlayableSource implements PlayableSource {
  final String path;
  @override
  final String title;

  const LocalPlayableSource({required this.path, required this.title});

  @override
  String get resumeKey => path;

  @override
  List<StreamQuality> get qualities => const [];

  @override
  Future<PlayStream> open(String qualityKey) async {
    return PlayStream(uri: path, qualityKey: StreamQuality.originKey);
  }
}

/// 百度网盘在线源。
class BaiduPlayableSource implements PlayableSource {
  final String cloudPath; // 云盘绝对路径

  /// fsid 可空：filemetas(dlink) 需要；仅在切到原画时按需解析。
  final int? fsId;
  @override
  final String title;

  const BaiduPlayableSource({
    required this.cloudPath,
    required this.title,
    this.fsId,
  });

  @override
  String get resumeKey => 'baidu://$cloudPath';

  @override
  List<StreamQuality> get qualities => const [
        StreamQuality('M3U8_AUTO_480', '480P'),
        StreamQuality('M3U8_AUTO_720', '720P'),
        StreamQuality('M3U8_AUTO_1080', '1080P'),
        StreamQuality(StreamQuality.originKey, '原画'),
      ];

  @override
  Future<PlayStream> open(String qualityKey) async {
    if (qualityKey.isEmpty) {
      final fsid = fsId ?? await BaiduApi.resolveFsid(cloudPath);
      final dlink = await BaiduApi.dlink(fsid);
      return PlayStream(
        uri: dlink,
        headers: const {'User-Agent': 'pan.baidu.com'},
        qualityKey: StreamQuality.originKey,
      );
    }
    final url = await BaiduApi.streamingUrl(cloudPath, qualityKey);
    return PlayStream(
      uri: url,
      headers: const {'User-Agent': 'srplayer/1.1;android;14'},
      qualityKey: qualityKey,
    );
  }
}
