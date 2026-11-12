import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models.dart';
import '../services/app_store.dart';
import '../services/netdisk/baidu_api.dart';
import '../services/netdisk/play_source.dart';
import '../services/shader_service.dart';
import '../state.dart';

/// 视频播放页：media_kit(libmpv) + Anime4K/ArtCNN GLSL 超分多档热切换。
/// 支持 [PlayableSource] 抽象：本地文件与百度网盘在线流统一打开；
/// 在线流带清晰度切换（换 URL 重开 + seek）、HLS 分片扩展名自愈、
/// 云端转码不可用时自动降级 dlink 原画（见 docs/网盘在线播放评估.md）。
class PlayerPage extends ConsumerStatefulWidget {
  final PlayableSource source;

  const PlayerPage({super.key, required this.source});

  /// 本地文件便捷入口（视频库/文件页/历史页调用）。
  factory PlayerPage.local(String path, {required String title}) {
    return PlayerPage(source: LocalPlayableSource(path: path, title: title));
  }

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  bool _ready = false;
  String _error = '';

  // 控制层状态。
  bool _showControls = true;
  bool _locked = false;
  Timer? _hideTimer;
  StreamSubscription? _posSub;
  StreamSubscription? _logSub;

  /// 当前由本页设置的 mpv vo；空串表示未干预（mpv 默认，Android 上通常为 gpu）。
  String _vo = '';

  /// 日志监听器记录的最近一条 vo fatal/error 文本，供 vo 探测自愈判断。
  String? _lastVoError;

  /// 当前清晰度 key（空串 = 原画/无清晰度概念）。
  String _quality = '';

  // —— 在线流打开自愈状态：等待 mpv 解析出轨道视为打开成功；
  //    期间收到 lavf/demux 错误（如分片扩展名被 ffmpeg 9 拒绝）则换下一档
  //    demuxer-lavf-o 重试。
  bool _pendingOpen = false;
  bool _gotTracks = false;
  String? _openFailure;
  StreamSubscription? _tracksSub;

  /// 续播保存门闩：流式源打开初期 position 从 0 上报，会覆盖续播点；
  /// 打开/换档期间仅当 position 达到 seek 目标后才允许写入，10s 兜底解除。
  int _saveGateMs = 0;
  Timer? _gateTimer;

  // 方向偏好循环：自动 → 横屏 → 竖屏。
  int _orientation = 0;

  /// HLS 分片无扩展名的兼容档位（ffmpeg 9=extension_picky，旧版=allowed_extensions）。
  static const _lavfLadder = [
    'extension_picky=0,allowed_extensions=ALL',
    'allowed_extensions=ALL',
    '',
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _player = Player();
    // 持久化为实验档时走创建时路径挂 gpu-next（Android 控制器会用此 vo
    // 覆盖 PlayerConfiguration，见 VideoControllerConfiguration 注释）；
    // 其余档位用默认 gpu。播放中切换档位由 _applySr 运行时处理。
    final persistedMode = ref.read(srModeProvider);
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        vo: persistedMode == SrMode.experimental ? 'gpu-next' : 'gpu',
      ),
    );
    _posSub = _player.stream.position
        .where((_) => _ready)
        .distinct()
        .listen((pos) {
      if (_saveGateMs > 0) {
        if (pos.inMilliseconds < _saveGateMs) return;
        _saveGateMs = 0; // 已观察到 seek 目标位置，恢复正常保存
      }
      _savePosition(pos);
    });
    _tracksSub = _player.stream.tracks.listen((_) {
      if (_pendingOpen) _gotTracks = true;
    });
    // mpv 日志（warn 及以上）打到 logcat，便于排查 shader / vo / 网络流问题。
    _logSub = _player.stream.log
        .where((e) =>
            e.level == 'warn' || e.level == 'error' || e.level == 'fatal')
        .listen((e) {
      debugPrint('[mpv/${e.level}] ${e.prefix}: ${e.text}');
      if (e.level == 'fatal' || (e.level == 'error' && e.prefix == 'vo')) {
        _lastVoError = '${e.prefix}: ${e.text}';
      }
      if (_pendingOpen &&
          (e.level == 'fatal' ||
              (e.level == 'error' &&
                  (e.prefix == 'lavf' ||
                      e.prefix == 'demux' ||
                      e.prefix == 'file' ||
                      e.prefix == 'hls' ||
                      e.prefix == 'avformat' ||
                      e.prefix == 'cplayer')))) {
        _openFailure ??= '${e.prefix}: ${e.text}';
      }
    });
    _open();
  }

  Future<void> _open() async {
    // 记住的清晰度（仅对支持清晰度的源生效）。
    String quality = '';
    if (widget.source.qualities.isNotEmpty) {
      final saved = AppStore.getString('netdisk_quality') ?? 'M3U8_AUTO_480';
      quality = widget.source.qualities.any((q) => q.key == saved)
          ? saved
          : widget.source.qualities.first.key;
    }
    // 本地源：续播位置在打开后 seek；在线源由 _openStream 透传。
    final saved = AppStore.getPosition(widget.source.resumeKey);
    final posMs = (saved?['pos'] as num?)?.toInt() ?? 0;
    await _openStream(qualityKey: quality, resumeMs: posMs);
  }

  /// 打开指定清晰度。resumeMs：续播/切清晰度时的回跳位置。
  Future<void> _openStream({
    required String qualityKey,
    int? resumeMs,
  }) async {
    if (!mounted) return;
    setState(() {
      _ready = false;
      _error = '';
      _quality = qualityKey;
    });
    PlayStream stream;
    try {
      stream = await widget.source.open(qualityKey);
    } on BaiduApiException catch (e) {
      // 云端转码不可用/无权限 → 自动降级 dlink 原画。
      final hasOrigin = widget.source.qualities.any((q) => q.key.isEmpty);
      if (qualityKey.isNotEmpty && hasOrigin && mounted) {
        debugPrint('[net] ${e}，自动降级原画');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('云端转码不可用（$e），已切换原画播放'),
          duration: const Duration(seconds: 3),
        ));
        return _openStream(qualityKey: '', resumeMs: resumeMs);
      }
      if (mounted) setState(() => _error = '$e');
      return;
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    await _openMedia(stream, resumeMs: resumeMs);
  }

  /// 打开媒体流；在线源带 demuxer-lavf-o 兼容阶梯。
  Future<void> _openMedia(PlayStream stream, {int? resumeMs}) async {
    final platform = _player.platform;
    final isNetwork = stream.isNetwork;
    try {
      if (platform is NativePlayer) {
        await platform.setProperty('sub-auto', 'fuzzy');
      }
      // 打开/换档期间锁住续播保存，防止 HLS 打开初期的低 position 覆盖续播点。
      var targetMs = resumeMs ?? 0;
      if (resumeMs == null) {
        final saved = AppStore.getPosition(widget.source.resumeKey);
        final durMs = (saved?['dur'] as num?)?.toInt() ?? 0;
        final savedPos = (saved?['pos'] as num?)?.toInt() ?? 0;
        if (savedPos > 5000 && (durMs <= 0 || savedPos < durMs * 0.95)) {
          targetMs = savedPos;
        }
      }
      _saveGateMs = targetMs;
      _gateTimer?.cancel();
      _gateTimer = Timer(const Duration(seconds: 10), () => _saveGateMs = 0);
      // 用 mpv 的 start 属性在加载期定位：HLS 打开初期 post-open seek 会被
      // demuxer 丢弃/竞态，start 由 mpv 在装载 m3u8 时原生处理，无此问题。
      if (platform is NativePlayer) {
        await platform.setProperty(
            'start', targetMs > 0 ? _mpvTime(targetMs) : 'none');
      }
      for (final attempt in isNetwork ? _lavfLadder : ['']) {
        if (platform is NativePlayer) {
          await platform.setProperty('demuxer-lavf-o', attempt);
        }
        _gotTracks = false;
        _openFailure = null;
        _pendingOpen = isNetwork;
        await _player.open(Media(stream.uri,
            httpHeaders: stream.headers.isEmpty ? null : stream.headers));
        // 等轨道解析成功（最多 10s）；期间出现 lavf/demux 错误则提前失败。
        final deadline =
            DateTime.now().add(const Duration(milliseconds: 10000));
        var ok = false;
        while (DateTime.now().isBefore(deadline)) {
          if (_gotTracks) {
            ok = true;
            break;
          }
          if (_openFailure != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        _pendingOpen = false;
        if (ok) break;
        debugPrint('[net] 打开失败（lavf-o="${attempt.isEmpty ? '默认' : attempt}"'
            '${_openFailure == null ? '' : ", $_openFailure"}），尝试下一档');
        await _player.stop();
      }
      if (!_gotTracks) {
        _saveGateMs = 0;
        if (mounted) {
          setState(() => _error =
              '播放失败：无法建立${isNetwork ? '网络' : ''}媒体流'
              '${_openFailure == null ? '' : '（$_openFailure）'}');
        }
        return;
      }
      // start 已让 mpv 在加载期定位；播放起来后校验到位，未到位则直 seek 补偿。
      await _player.play();
      if (targetMs > 0) {
        var settled = false;
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final now = _player.state.position.inMilliseconds;
          if (now >= targetMs * 0.5 && (now - targetMs).abs() <= 15000) {
            settled = true;
            break;
          }
          if (i == 9) {
            debugPrint('[net] start 未生效（now=$now, want=$targetMs），直 seek 补偿');
            await _player.seek(Duration(milliseconds: targetMs));
          }
        }
        if (!settled) debugPrint('[net] 续播位置校验未通过（可能仍在缓冲）');
        _saveGateMs = 0; // 定位完成，恢复正常保存
      } else {
        _saveGateMs = 0;
      }
      if (platform is NativePlayer) {
        await platform.setProperty('start', 'none'); // 清理，避免影响后续打开
      }
      // 应用当前 SR 档位。
      await _applySr(ref.read(srModeProvider), notify: false);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 切换清晰度：记录当前位置 → 换 URL 重开 → seek 回原位置。
  Future<void> _switchQuality(String key) async {
    if (key == _quality) return;
    if (key.isNotEmpty) {
      await AppStore.setString('netdisk_quality', key);
    }
    final pos = _player.state.position.inMilliseconds;
    await _openStream(
        qualityKey: key, resumeMs: pos > 0 ? pos : null);
  }

  /// mpv start 属性的时间格式（秒，含毫秒）。
  String _mpvTime(int ms) => (ms / 1000).toStringAsFixed(3);

  String get _qualityLabel {
    for (final q in widget.source.qualities) {
      if (q.key == _quality) return q.label;
    }
    return '';
  }

  /// 切换超分档位：解析 shader → setProperty 热挂载，无需重建播放器。
  Future<void> _applySr(SrMode mode, {bool notify = true}) async {
    try {
      final paths = await ShaderService.resolveChain(mode);
      final platform = _player.platform;
      if (platform is NativePlayer) {
        // 实验档的 ArtCNN 是 compute shader，仅 gpu-next(libplacebo) 渲染器支持。
        // 能力由打包的 libmpv 构建决定，静态开关优先，避免在播放中试错。
        if (mode == SrMode.experimental && !ShaderService.gpuNextAvailable) {
          if (notify && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('当前播放内核不含 gpu-next，实验档不可用'),
              duration: Duration(seconds: 2),
            ));
          }
          return;
        }
        // 其余档位沿用默认 vo（Android 上通常为 gpu）。mpv 的 vo 支持运行时热切换。
        final wantVo = mode == SrMode.experimental ? 'gpu-next' : 'gpu';
        if (_vo != wantVo && (mode == SrMode.experimental || _vo.isNotEmpty)) {
          final ok = await _switchVo(platform, wantVo);
          if (!ok && mode == SrMode.experimental) {
            if (notify && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('当前播放内核不支持 gpu-next，实验档不可用'),
                duration: Duration(seconds: 2),
              ));
            }
            return;
          }
        }
        // glsl-shaders 是 mpv 的路径列表选项：分隔符在 Unix/Android 上是 ':'（Windows 为 ';'），
        // 用 ',' 会被当成一个整体路径，导致 Cannot open file、shader 静默不挂载。
        await platform.setProperty(
            'glsl-shaders', paths.join(Platform.isWindows ? ';' : ':'));
        // 诊断：稍候 vo 初始化完成后输出实际生效的渲染器到 logcat。
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final vo = await platform.getProperty('current-vo');
        debugPrint('[sr] mode=$mode glsl=${paths.length} current-vo=$vo');
      }
      if (notify && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              mode == SrMode.off ? '超分辨率：关闭' : '超分辨率：${mode.label}档（${paths.length} 个着色器）',
            ),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (notify && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换失败：$e')));
      }
    }
  }

  /// 热切换 mpv vo。预编译 libmpv 可能不含 gpu-next（media-kit v1.1.7 实测缺失），
  /// 盲切会让视频输出初始化失败（画面卡死、音频继续），因此切换后监听一小段
  /// 时间的 vo fatal 日志，出错立即回退 gpu 并返回 false。成功时更新 _vo。
  Future<bool> _switchVo(NativePlayer platform, String vo) async {
    _lastVoError = null;
    await platform.setProperty('vo', vo);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (_lastVoError != null) {
      debugPrint('[sr] vo switch to $vo failed: $_lastVoError, reverting');
      await platform.setProperty('vo', 'gpu');
      return false;
    }
    _vo = vo;
    return true;
  }

  void _savePosition(Duration pos) {
    if (_saveGateMs > 0 && pos.inMilliseconds < _saveGateMs) return;
    final dur = _player.state.duration.inMilliseconds;
    final p = pos.inMilliseconds;
    if (p <= 0 || (dur > 0 && p >= dur * 0.95)) return;
    AppStore.recordPlayback(
        path: widget.source.resumeKey,
        name: widget.source.title,
        posMs: p,
        durMs: dur);
  }

  @override
  void dispose() {
    final dur = _player.state.duration.inMilliseconds;
    final pos = _player.state.position.inMilliseconds;
    if (pos > 0 && (dur <= 0 || pos < dur * 0.95)) {
      AppStore.recordPlayback(
          path: widget.source.resumeKey,
          name: widget.source.title,
          posMs: pos,
          durMs: dur);
    }
    _posSub?.cancel();
    _logSub?.cancel();
    _tracksSub?.cancel();
    _hideTimer?.cancel();
    _gateTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 强制恢复竖屏：主界面（视频库/文件/网盘/我的）均为竖屏设计，
    // 不能依赖 '[]'(自动) 恢复——自动旋转关闭或模拟器无传感器时横屏会残留。
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _player.dispose();
    super.dispose();
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _showControls = !_showControls);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _cycleOrientation() {
    _orientation = (_orientation + 1) % 3;
    switch (_orientation) {
      case 0:
        SystemChrome.setPreferredOrientations([]);
      case 1:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      case 2:
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }

  Future<void> _showSrSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final mode = ref.watch(srModeProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('画面设置 · 超分辨率',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '基于 Anime4K / ArtCNN GLSL 着色器，热切换无需重启播放。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              for (final m in SrMode.values)
                RadioListTile<SrMode>(
                  value: m,
                  groupValue: mode,
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(srModeProvider.notifier).set(v);
                      _applySr(v);
                    }
                  },
                  title: Text(m == SrMode.off ? '关闭' : m.label),
                  subtitle: Text(m.desc, style: const TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('播放失败')),
        body: Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _openStream(
                    qualityKey: _quality),
                child: const Text('重试'),
              ),
            ],
          ),
        )),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _ready
                ? Video(controller: _controller, controls: NoVideoControls)
                : const CircularProgressIndicator(),
          ),
          // 控制层。
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              behavior: HitTestBehavior.translucent,
              child: AnimatedOpacity(
                opacity: _showControls && !_locked ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls || _locked,
                  child: _buildControls(),
                ),
              ),
            ),
          ),
          if (_locked)
            Positioned(
              right: 16,
              bottom: 16,
              child: IconButton.filledTonal(
                onPressed: () => setState(() => _locked = false),
                icon: const Icon(Icons.lock_open),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        // 顶部栏。
        Container(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 4),
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
              Expanded(
                child: Text(
                  widget.source.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                tooltip: '画面设置',
                onPressed: _showSrSheet,
                icon: const Icon(Icons.tune, color: Colors.white),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        const Spacer(),
        // 底部栏。
        Container(
          padding: EdgeInsets.only(
            left: 8, right: 8, bottom: MediaQuery.of(context).padding.bottom + 4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekBar(player: _player),
              Row(children: [
                _StreamPlayButton(player: _player),
                IconButton(
                  onPressed: _cycleOrientation,
                  icon: const Icon(Icons.screen_rotation, color: Colors.white),
                  tooltip: '方向',
                ),
                IconButton(
                  onPressed: () => setState(() => _locked = true),
                  icon: const Icon(Icons.lock_outline, color: Colors.white),
                  tooltip: '锁定控制',
                ),
                const Spacer(),
                // 倍速。
                PopupMenuButton<double>(
                  tooltip: '倍速',
                  onSelected: (s) => _player.setRate(s),
                  icon: const Icon(Icons.speed, color: Colors.white),
                  itemBuilder: (_) => [
                    for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                      PopupMenuItem(value: v, child: Text('$v x')),
                  ],
                ),
                // 清晰度（仅在线源显示）。
                if (widget.source.qualities.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: '清晰度',
                    onSelected: _switchQuality,
                    itemBuilder: (_) => [
                      for (final q in widget.source.qualities)
                        CheckedPopupMenuItem(
                          value: q.key,
                          checked: q.key == _quality,
                          child: Text(q.label),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        _qualityLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: '超分辨率',
                  onPressed: _showSrSheet,
                  icon: Badge(
                    isLabelVisible: ref.read(srModeProvider) != SrMode.off,
                    child: const Icon(Icons.auto_awesome, color: Colors.white),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// 进度条：position/duration 流 + 拖动 seek。
class _SeekBar extends StatefulWidget {
  final Player player;
  const _SeekBar({required this.player});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double _dragValue = -1;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      builder: (context, posSnap) {
        return StreamBuilder<Duration>(
          stream: widget.player.stream.duration,
          builder: (context, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final maxS = dur.inMilliseconds / 1000.0;
            final value = _dragValue >= 0
                ? _dragValue
                : (pos.inMilliseconds / 1000.0).clamp(0.0, maxS <= 0 ? 0.0 : maxS);
            String fmt(Duration d) {
              final s = d.inSeconds;
              final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
              String two(int v) => v.toString().padLeft(2, '0');
              return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
            }
            return Row(
              children: [
                Text(fmt(pos), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: value,
                    max: maxS <= 0 ? 1.0 : maxS,
                    onChanged: maxS <= 0
                        ? null
                        : (v) => setState(() => _dragValue = v),
                    onChangeEnd: (v) async {
                      await widget.player.seek(Duration(milliseconds: (v * 1000).round()));
                      if (mounted) setState(() => _dragValue = -1);
                    },
                  ),
                ),
                Text(fmt(dur), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            );
          },
        );
      },
    );
  }
}

class _StreamPlayButton extends StatelessWidget {
  final Player player;
  const _StreamPlayButton({required this.player});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return IconButton(
          iconSize: 36,
          color: Colors.white,
          onPressed: () => player.playOrPause(),
          icon: Icon(playing ? Icons.pause_circle_outline : Icons.play_circle_outline),
        );
      },
    );
  }
}
