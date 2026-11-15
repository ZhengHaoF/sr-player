import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:window_manager/window_manager.dart';

import '../models.dart';
import '../services/app_store.dart';
import '../services/netdisk/baidu_api.dart';
import '../services/netdisk/play_source.dart';
import '../services/shader_service.dart';
import '../state.dart';

/// 竖滑手势类型：左 1/3 屏幕调亮度，右 1/3 调音量，中间不响应竖滑。
enum _DragKind { brightness, volume }

/// 视频播放页：media_kit(libmpv) + Anime4K/ArtCNN GLSL 超分多档热切换。
/// 支持 [PlayableSource] 抽象：本地文件与百度网盘在线流统一打开；
/// 在线流带清晰度切换（换 URL 重开 + seek）、HLS 分片扩展名自愈、
/// 云端转码不可用时自动降级 dlink 原画（见 docs/网盘在线播放评估.md）。
/// 手势：单击切换控制层，双击播放/暂停，左右竖滑调亮度/音量（带 HUD）。
class PlayerPage extends ConsumerStatefulWidget {
  final PlayableSource source;

  const PlayerPage({super.key, required this.source});

  /// 本地文件便捷入口（视频库/文件页/历史页调用）。
  factory PlayerPage.local(String path, {required String title}) {
    return PlayerPage(
      source: LocalPlayableSource(path: path, title: title),
    );
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

  /// 桌面端窗口全屏状态（移动端本就全屏，恒为 false）。
  bool _isFullscreen = false;

  /// 当前生效的 mpv vo。initState 按持久化档位登记（经 Android 控制器配置，
  /// 首帧加载时由控制器统一写入 mpv），播放中切档由 [_applySr] 运行时接管。
  String _vo = '';

  /// 日志监听器记录的最近一条 vo fatal/error 文本，供 vo 探测自愈判断。
  String? _lastVoError;

  /// 当前清晰度 key（空串 = 原画/无清晰度概念）。
  String _quality = '';

  // —— 在线流打开自愈状态：等待 mpv 解析出轨道视为打开成功；
  //    期间收到 lavf/demux 错误（如分片扩展名被 ffmpeg 9 拒绝）则换下一档
  //    demuxer-lavf-o 重试。
  //    _awaitingTracks 与 _pendingOpen 分开：本地源同样要等轨道（否则必然
  //    等满 10s 超时误判打开失败），lavf 错误检测则仅对在线流生效——本地
  //    存在 benign lavf error（file cache）不应中断打开。
  bool _pendingOpen = false;
  bool _awaitingTracks = false;
  bool _gotTracks = false;
  String? _openFailure;
  StreamSubscription? _tracksSub;

  /// 续播保存门闩：流式源打开初期 position 从 0 上报，会覆盖续播点；
  /// 打开/换档期间仅当 position 达到 seek 目标后才允许写入，10s 兜底解除。
  int _saveGateMs = 0;
  Timer? _gateTimer;

  /// 打开代际：每次 [_openMedia] 递增，用于作废仍在跑的后台收尾
  /// （加载期间换清晰度/重开的场景）。
  int _openSeq = 0;

  // 方向偏好循环：自动 → 横屏 → 竖屏。
  int _orientation = 0;

  // —— 竖滑调亮度/音量 ——
  _DragKind? _dragKind; // 进行中的竖滑类型（null = 无）
  double _dragBase = 0; // 竖滑起点的亮度/音量
  double _dragAccum = 0; // 竖滑累计位移（按屏高归一化）
  double _brightness = 0.5; // 亮度/音量缓存，手势间保持连续
  double _volume = 0.5;
  bool _brightnessSupported = true; // 插件探测失败的平台禁用对应手势
  bool _volumeSupported = true;
  bool _brightnessAdjusted = false; // 本次播放页设置过应用亮度（退出时还原）
  _DragKind? _hudKind; // HUD 最后展示的侧别（松手淡出期间保持）
  bool _hudVisible = false;
  Timer? _hudTimer;

  // 双击播放/暂停的中心闪烁图标；null = 不显示。
  bool? _playFlash;
  Timer? _flashTimer;

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
    // vo 覆盖仅限 Android：Android 走 wid/surface 嵌入，覆盖 vo 换取超分档位。
    // 桌面端（Windows/Linux/macOS）内嵌渲染走 render API，要求 vo=libmpv
    // （NativeVideoController 的默认值）——覆盖成 gpu/gpu-next 会让 mpv 自建
    // 窗口播放（标题 package:media_kit），视频飘出应用、主窗口只剩占位 logo。
    final bool voOverrideAllowed = Platform.isAndroid;
    final persistedMode = ref.read(srModeProvider);
    final initialVo = voOverrideAllowed
        ? (persistedMode == SrMode.experimental &&
                  ShaderService.gpuNextAvailable
              ? 'gpu-next'
              : 'gpu')
        : null;
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(vo: initialVo),
    );
    // 创建时路径的 vo 由控制器在首帧加载时统一写入 mpv，这里同步登记到
    // _vo，避免 _applySr 首次打开时再写一次同值 vo——mpv 对 vo 属性的
    // 运行时写入会销毁重建 VO，撞上首帧初始化会偶发渲染链卡死（黑屏有声）。
    _vo = initialVo ?? '';
    _posSub = _player.stream.position.where((_) => _ready).distinct().listen((
      pos,
    ) {
      if (_saveGateMs > 0) {
        if (pos.inMilliseconds < _saveGateMs) return;
        _saveGateMs = 0; // 已观察到 seek 目标位置，恢复正常保存
      }
      _savePosition(pos);
    });
    _tracksSub = _player.stream.tracks.listen((_) {
      if (_awaitingTracks) _gotTracks = true;
    });
    // mpv 日志（warn 及以上）打到 logcat，便于排查 shader / vo / 网络流问题。
    _logSub = _player.stream.log
        .where(
          (e) => e.level == 'warn' || e.level == 'error' || e.level == 'fatal',
        )
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
    // 手势能力探测：读不到当前值说明平台未实现插件（如音量控制的桌面端），
    // 静默禁用对应手势，避免播放中抛 MissingPluginException。
    ScreenBrightness.instance.application.then(
      (v) => _brightness = v,
      onError: (_) => _brightnessSupported = false,
    );
    VolumeController.instance
      ..showSystemUI =
          false // 音量 HUD 自绘，不叠加系统条
      ..getVolume().then(
        (v) => _volume = v,
        onError: (_) => _volumeSupported = false,
      );
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
  Future<void> _openStream({required String qualityKey, int? resumeMs}) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('云端转码不可用（$e），已切换原画播放'),
            duration: const Duration(seconds: 3),
          ),
        );
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
    _openSeq++; // 作废上一轮仍在跑的后台收尾
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
          'start',
          targetMs > 0 ? _mpvTime(targetMs) : 'none',
        );
      }
      for (final attempt in isNetwork ? _lavfLadder : ['']) {
        if (platform is NativePlayer) {
          await platform.setProperty('demuxer-lavf-o', attempt);
        }
        _gotTracks = false;
        _openFailure = null;
        _pendingOpen = isNetwork;
        _awaitingTracks = true;
        await _player.open(
          Media(
            stream.uri,
            httpHeaders: stream.headers.isEmpty ? null : stream.headers,
          ),
        );
        // 等轨道解析成功（最多 10s）；期间出现 lavf/demux 错误则提前失败。
        final deadline = DateTime.now().add(
          const Duration(milliseconds: 10000),
        );
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
        _awaitingTracks = false;
        if (ok) break;
        debugPrint(
          '[net] 打开失败（lavf-o="${attempt.isEmpty ? '默认' : attempt}"'
          '${_openFailure == null ? '' : ", $_openFailure"}），尝试下一档',
        );
        await _player.stop();
      }
      if (!_gotTracks) {
        _saveGateMs = 0;
        if (mounted) {
          setState(
            () => _error =
                '播放失败：无法建立${isNetwork ? '网络' : ''}媒体流'
                '${_openFailure == null ? '' : '（$_openFailure）'}',
          );
        }
        return;
      }
      // start 已让 mpv 在加载期定位；播放起来后校验到位，未到位则直 seek 补偿。
      // 每个视频都新建 Player 实例，持久化倍速必须在打开时重设。
      await _player.setRate(ref.read(playbackRateProvider));
      await _player.play();
      // 轨道已确认、play 已发起：mpv 已在出流（音频/进度先走），此时就应展示
      // 画面。续播校验与 SR 挂载是补偿/配置性质，转后台跑，不再以固定延迟
      // （校验循环 ≥500ms + 诊断 1.2s）推迟首帧。
      if (!mounted) return;
      setState(() => _ready = true);
      unawaited(_postOpenSettle(targetMs));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 打开后的后台收尾：续播位置校验/补偿、start 清理、挂载当前 SR 档位。
  /// 与 [_openMedia] 主体解耦，不阻塞首帧展示。
  Future<void> _postOpenSettle(int targetMs) async {
    final seq = _openSeq;
    final srMode = ref.read(srModeProvider);
    if (targetMs > 0) {
      var settled = false;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || seq != _openSeq) return;
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
    }
    if (seq != _openSeq) return; // 期间已重开，本轮收尾作废
    _saveGateMs = 0; // 定位完成，恢复正常保存
    if (!mounted) return;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('start', 'none'); // 清理，避免影响后续打开
    }
    // 应用当前 SR 档位。
    await _applySr(srMode, notify: false);
  }

  /// 切换清晰度：记录当前位置 → 换 URL 重开 → seek 回原位置。
  Future<void> _switchQuality(String key) async {
    if (key == _quality) return;
    if (key.isNotEmpty) {
      await AppStore.setString('netdisk_quality', key);
    }
    final pos = _player.state.position.inMilliseconds;
    await _openStream(qualityKey: key, resumeMs: pos > 0 ? pos : null);
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
        // 实验档的 ArtCNN 是 compute shader，仅 gpu-next(libplacebo) 渲染器支持：
        // Android 上由打包内核决定（静态开关优先，避免播放中试错）；桌面端走
        // render API 内嵌渲染，渲染器固定为 gpu，无法切 gpu-next，一律不可用。
        if (mode == SrMode.experimental &&
            (!ShaderService.gpuNextAvailable || !Platform.isAndroid)) {
          if (notify && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('桌面端实验档不可用：内嵌渲染走 render API，不含 gpu-next'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        // Android：档位热切 vo（mpv 支持运行时切换）；桌面端 vo 必须保持
        // libmpv（覆盖即飘窗），仅挂 glsl-shaders。
        final wantVo = mode == SrMode.experimental ? 'gpu-next' : 'gpu';
        if (Platform.isAndroid &&
            _vo != wantVo &&
            (mode == SrMode.experimental || _vo.isNotEmpty)) {
          final ok = await _switchVo(platform, wantVo);
          if (!ok && mode == SrMode.experimental) {
            if (notify && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('当前播放内核不支持 gpu-next，实验档不可用'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
            return;
          }
        }
        // glsl-shaders 是 mpv 的路径列表选项：分隔符在 Unix/Android 上是 ':'（Windows 为 ';'），
        // 用 ',' 会被当成一个整体路径，导致 Cannot open file、shader 静默不挂载。
        await platform.setProperty(
          'glsl-shaders',
          paths.join(Platform.isWindows ? ';' : ':'),
        );
        // 诊断：稍候 vo 初始化完成后输出实际生效的渲染器到 logcat。
        // 不 await：固定延迟若阻塞在此，每次打开都会白付 1.2s 才出画面。
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 1200), () async {
            try {
              final vo = await platform.getProperty('current-vo');
              debugPrint('[sr] mode=$mode glsl=${paths.length} current-vo=$vo');
            } catch (_) {
              // 播放器已释放等场景，诊断失败无碍
            }
          }),
        );
      }
      if (notify && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              mode == SrMode.off
                  ? '超分辨率：关闭'
                  : '超分辨率：${mode.label}档（${paths.length} 个着色器）',
            ),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (notify && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切换失败：$e')));
      }
    }
  }

  /// 桌面端窗口全屏切换。移动端本就全屏，入口都不显示。
  Future<void> _toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    final next = !_isFullscreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _isFullscreen = next);
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
      durMs: dur,
    );
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
        durMs: dur,
      );
    }
    _posSub?.cancel();
    _logSub?.cancel();
    _tracksSub?.cancel();
    _hideTimer?.cancel();
    _gateTimer?.cancel();
    _hudTimer?.cancel();
    _flashTimer?.cancel();
    // 应用级亮度挂在 Activity 窗口上，回到主界面不会自动消失，
    // 退出播放页必须还原，避免视频库/文件页继承调暗后的亮度。
    if (_brightnessAdjusted) {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    }
    // 播放页被退出时还原桌面端窗口全屏，避免主界面残留无边框全屏。
    if (_isFullscreen) {
      windowManager.setFullScreen(false);
    }
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

  /// 竖滑起点分区：左 1/3 调亮度、右 1/3 调音量、中间不响应。
  /// 起点值用同步缓存；随后异步读一次真实值兜底（系统侧可能改过），
  /// 用户已拖动（_dragAccum != 0）则放弃刷新，防止 HUD 跳变。
  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked) return;
    final w = MediaQuery.of(context).size.width;
    if (d.localPosition.dx <= w / 3 && _brightnessSupported) {
      _dragKind = _DragKind.brightness;
      _dragBase = _brightness;
      ScreenBrightness.instance.application.then((v) {
        if (_dragKind == _DragKind.brightness && _dragAccum == 0) {
          _dragBase = v.clamp(0.05, 1.0);
        }
      }, onError: (_) {});
    } else if (d.localPosition.dx >= w * 2 / 3 && _volumeSupported) {
      _dragKind = _DragKind.volume;
      _dragBase = _volume;
      VolumeController.instance.getVolume().then((v) {
        if (_dragKind == _DragKind.volume && _dragAccum == 0) _dragBase = v;
      }, onError: (_) {});
    } else {
      _dragKind = null;
      return;
    }
    _dragAccum = 0;
    _hudKind = _dragKind;
    _hudTimer?.cancel();
    setState(() => _hudVisible = true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_dragKind == null) return;
    // 上滑增大；一整个屏高 ≈ 全量程 0~1。
    _dragAccum += -d.delta.dy / MediaQuery.of(context).size.height;
    final raw = _dragBase + _dragAccum;
    if (_dragKind == _DragKind.brightness) {
      _brightness = raw.clamp(0.05, 1.0); // 0 会导致息屏，保底 5%
      _brightnessAdjusted = true;
      ScreenBrightness.instance.setApplicationScreenBrightness(_brightness);
    } else {
      _volume = raw.clamp(0.0, 1.0);
      VolumeController.instance.setVolume(_volume);
    }
    setState(() {});
  }

  /// 松手/取消（被 arena 判给 Slider 等）后延迟淡出 HUD。
  void _onVerticalDragEnd([DragEndDetails? _]) {
    _dragKind = null;
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  /// 双击切换播放/暂停，中心闪一个大图标做反馈。
  void _onDoubleTap() {
    if (_locked) return;
    final willPlay = !_player.state.playing;
    _player.playOrPause();
    _flashTimer?.cancel();
    setState(() => _playFlash = willPlay);
    _flashTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _playFlash = null);
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
      // 小屏上固定内容会超出默认 9/16 高度上限，允许弹层撑高并让列表滚动。
      isScrollControlled: true,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final mode = ref.watch(srModeProvider);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '画面设置 · 超分辨率',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '基于 Anime4K / ArtCNN GLSL 着色器，热切换无需重启播放。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 桌面端内嵌渲染（render API）不含 gpu-next，实验档不展示。
                        for (final m in SrMode.values)
                          if (m != SrMode.experimental || Platform.isAndroid)
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
                              subtitle: Text(
                                m.desc,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 视频详情：打开弹层时读取一次参数快照（mpv 状态 + 少量属性查询）。
  Future<void> _showInfoSheet() async {
    final groups = await _collectInfoGroups(
      player: _player,
      srMode: ref.read(srModeProvider),
      source: widget.source,
      qualityLabel: _qualityLabel,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      // 参数分组较多，允许弹层撑高并让内容滚动（与画面设置弹层同策略）。
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '视频信息',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '打开弹层时读取的参数快照。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final g in groups) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                        child: Text(
                          g.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      for (final (label, value) in g.rows)
                        _infoRow(label, value),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('播放失败')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _openStream(qualityKey: _quality),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 桌面端快捷键：F11 切换全屏，Esc 退出全屏。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_isFullscreen) {
            _toggleFullscreen();
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Center(
                child: _ready
                    ? Video(controller: _controller, controls: NoVideoControls)
                    : const CircularProgressIndicator(),
              ),
              // 控制层。手势：单击控制层开关、双击播放/暂停、左右竖滑亮度/音量。
              // 与底部进度条靠手势竞技场仲裁：横向移动归 Slider，竖向归本层。
              Positioned.fill(
                child: GestureDetector(
                  onTap: _toggleControls,
                  onDoubleTap: _onDoubleTap,
                  onVerticalDragStart: _onVerticalDragStart,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onVerticalDragEnd: _onVerticalDragEnd,
                  onVerticalDragCancel: _onVerticalDragEnd,
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
              // 竖滑 HUD：显示在对应半区中心，松手 700ms 后淡出。
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hudVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Align(
                      alignment: Alignment(
                        _hudKind == _DragKind.brightness ? -2 / 3 : 2 / 3,
                        0,
                      ),
                      child: _hudKind == null
                          ? const SizedBox.shrink()
                          : _buildHudCard(_hudKind!),
                    ),
                  ),
                ),
              ),
              // 双击播放/暂停的中心反馈图标。
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _playFlash != null ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _playFlash == true
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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
                tooltip: '视频信息',
                onPressed: _showInfoSheet,
                icon: const Icon(Icons.info_outline, color: Colors.white),
              ),
              // 桌面端全屏切换；移动端本就全屏，不显示入口。
              if (!Platform.isAndroid && !Platform.isIOS)
                IconButton(
                  tooltip: _isFullscreen ? '退出全屏' : '全屏',
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                    _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white,
                  ),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        const Spacer(),
        // 底部栏。
        Container(
          padding: EdgeInsets.only(
            left: 8,
            right: 8,
            bottom: MediaQuery.of(context).padding.bottom + 4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekBar(player: _player),
              Row(
                children: [
                  _StreamPlayButton(player: _player),
                  IconButton(
                    onPressed: _cycleOrientation,
                    icon: const Icon(
                      Icons.screen_rotation,
                      color: Colors.white,
                    ),
                    tooltip: '方向',
                  ),
                  IconButton(
                    onPressed: () => setState(() => _locked = true),
                    icon: const Icon(Icons.lock_outline, color: Colors.white),
                    tooltip: '锁定控制',
                  ),
                  const Spacer(),
                  // 倍速（跨视频/会话持久化，打开媒体时恢复）。
                  PopupMenuButton<double>(
                    tooltip: '倍速',
                    icon: const Icon(Icons.speed, color: Colors.white),
                    onSelected: (s) {
                      ref.read(playbackRateProvider.notifier).set(s);
                      _player.setRate(s);
                    },
                    itemBuilder: (_) => [
                      for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                        CheckedPopupMenuItem(
                          value: v,
                          checked: v == ref.read(playbackRateProvider),
                          child: Text('$v x'),
                        ),
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
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '超分辨率',
                    onPressed: _showSrSheet,
                    icon: Badge(
                      isLabelVisible: ref.read(srModeProvider) != SrMode.off,
                      child: const Icon(
                        Icons.auto_awesome,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 竖滑 HUD：图标 + 竖向进度条 + 百分比，贴对应半区中心。
  Widget _buildHudCard(_DragKind kind) {
    final value = kind == _DragKind.brightness ? _brightness : _volume;
    final icon = kind == _DragKind.brightness
        ? Icons.brightness_6_outlined
        : value <= 0.02
        ? Icons.volume_off
        : value < 0.5
        ? Icons.volume_down
        : Icons.volume_up;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              width: 6,
              height: 130,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(color: Colors.white24),
                  FractionallySizedBox(
                    heightFactor: value,
                    child: Container(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
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
                : (pos.inMilliseconds / 1000.0).clamp(
                    0.0,
                    maxS <= 0 ? 0.0 : maxS,
                  );
            String fmt(Duration d) {
              final s = d.inSeconds;
              final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
              String two(int v) => v.toString().padLeft(2, '0');
              return h > 0
                  ? '$h:${two(m)}:${two(sec)}'
                  : '${two(m)}:${two(sec)}';
            }

            return Row(
              children: [
                Text(
                  fmt(pos),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                Expanded(
                  child: Slider(
                    value: value,
                    max: maxS <= 0 ? 1.0 : maxS,
                    onChanged: maxS <= 0
                        ? null
                        : (v) => setState(() => _dragValue = v),
                    onChangeEnd: (v) async {
                      await widget.player.seek(
                        Duration(milliseconds: (v * 1000).round()),
                      );
                      if (mounted) setState(() => _dragValue = -1);
                    },
                  ),
                ),
                Text(
                  fmt(dur),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
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
          icon: Icon(
            playing ? Icons.pause_circle_outline : Icons.play_circle_outline,
          ),
        );
      },
    );
  }
}

// —— 视频详情弹层（顶栏"视频信息"按钮）——

/// 视频详情的一个分组；rows 为 (标签, 值) 对，值缺失的行在收集时省略。
class _InfoGroup {
  final String title;
  final List<(String, String)> rows;
  const _InfoGroup(this.title, this.rows);
}

/// 详情弹层一行：左侧灰色标签，右侧取值。
Widget _infoRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );
}

/// mpv 属性查询：非 native 内核或属性缺失时返回 null。
Future<String?> _mpvProp(Player player, String name) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return null;
  try {
    return await platform.getProperty(name);
  } catch (_) {
    return null;
  }
}

/// state.track 在流刚打开时可能仍停留 auto/no，回退到第一条真实轨道。
T _activeTrack<T>(T selected, List<T> all, String Function(T) id) {
  if (id(selected) != 'auto' && id(selected) != 'no') return selected;
  final real = _realTracks(all, id);
  return real.isEmpty ? selected : real.first;
}

/// 过滤 mpv 的 auto/no 伪轨道。
List<T> _realTracks<T>(List<T> all, String Function(T) id) =>
    all.where((t) => id(t) != 'auto' && id(t) != 'no').toList();

/// 汇总视频详情各分组：快照取自 player.state，少量属性走 mpv 查询。
Future<List<_InfoGroup>> _collectInfoGroups({
  required Player player,
  required SrMode srMode,
  required PlayableSource source,
  required String qualityLabel,
}) async {
  final st = player.state;
  final vt = _activeTrack(st.track.video, st.tracks.video, (t) => t.id);
  final at = _activeTrack(st.track.audio, st.tracks.audio, (t) => t.id);
  final vp = st.videoParams;
  final ap = st.audioParams;

  final groups = <_InfoGroup>[];

  // —— 视频流参数 ——
  final video = <(String, String)>[];
  final (w, h) = (vt.w ?? vp.w, vt.h ?? vp.h);
  if (w != null && h != null && w > 0) video.add(('分辨率', '$w × $h'));
  final rotate = vt.rotate ?? vp.rotate;
  if (rotate != null && rotate > 0) video.add(('旋转', '$rotate°'));
  final fps = vt.fps;
  if (fps != null && fps > 0) video.add(('帧率', _fmtFps(fps)));
  if (vt.codec?.isNotEmpty ?? false) video.add(('视频编码', vt.codec!));
  final pixfmt = vp.pixelformat;
  if (pixfmt != null && pixfmt != 'unknown') video.add(('像素格式', pixfmt));
  final color = _colorLabel(vp);
  if (color.isNotEmpty) video.add(('色域 / HDR', color));
  final vbps = vt.bitrate;
  if (vbps != null && vbps > 0) video.add(('视频码率', _fmtBitrate(vbps)));
  if (video.isNotEmpty) groups.add(_InfoGroup('视频', video));

  // —— 音频流参数 ——
  final audio = <(String, String)>[];
  if (at.codec?.isNotEmpty ?? false) audio.add(('音频编码', at.codec!));
  final sampleRate = at.samplerate ?? ap.sampleRate;
  if (sampleRate != null && sampleRate > 0)
    audio.add(('采样率', _fmtKhz(sampleRate)));
  final chCount = at.channelscount ?? ap.channelCount;
  final chLayout = at.channels ?? ap.channels;
  if (chCount != null && chCount > 0) {
    audio.add((
      '声道',
      chLayout?.isEmpty == false ? '$chCount 声道（$chLayout）' : '$chCount 声道',
    ));
  }
  final abps = at.bitrate;
  if (abps != null && abps > 0) audio.add(('音频码率', _fmtBitrate(abps)));
  if (audio.isNotEmpty) groups.add(_InfoGroup('音频', audio));

  // —— 轨道 ——
  final aTracks = _realTracks(st.tracks.audio, (t) => t.id);
  final sTracks = _realTracks(st.tracks.subtitle, (t) => t.id);
  groups.add(
    _InfoGroup('轨道', [
      (
        '音轨',
        aTracks.isEmpty
            ? '无'
            : '${aTracks.length} 条${_langSuffix(aTracks.map((t) => t.language))}',
      ),
      (
        '字幕',
        sTracks.isEmpty
            ? '无'
            : '${sTracks.length} 条${_langSuffix(sTracks.map((t) => t.language))}',
      ),
    ]),
  );

  // —— 播放器 ——
  final vo = await _mpvProp(player, 'current-vo');
  final hwdec = await _mpvProp(player, 'hwdec-current');
  final fileFormat = await _mpvProp(player, 'file-format');
  final playerRows = <(String, String)>[
    ('渲染器', vo?.isEmpty == false ? vo! : '默认'),
    ('解码', _hwdecLabel(hwdec)),
    ('超分档位', srMode == SrMode.off ? '关闭' : '${srMode.label}档'),
  ];
  if (qualityLabel.isNotEmpty) playerRows.add(('清晰度', qualityLabel));
  groups.add(_InfoGroup('播放器', playerRows));

  // —— 文件 ——
  final file = <(String, String)>[];
  if (fileFormat?.isNotEmpty ?? false) file.add(('容器格式', fileFormat!));
  if (source is LocalPlayableSource) {
    try {
      final stat = await File(source.path).stat();
      file.add(('大小', _fmtBytes(stat.size)));
      file.add(('修改时间', _fmtDate(stat.modified)));
    } catch (_) {
      // 路径不可读（如 content:// 条目）时省略大小/时间行。
    }
  }
  final dur = st.duration;
  if (dur > Duration.zero) file.add(('时长', _fmtDuration(dur)));
  if (file.isNotEmpty) groups.add(_InfoGroup('文件', file));

  return groups;
}

/// 语言后缀：无有效语言返回空串，否则形如（chi、eng）。
String _langSuffix(Iterable<String?> langs) {
  final names = langs
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  return names.isEmpty ? '' : '（${names.join('、')}）';
}

/// 色域/HDR 简述：PQ/HLG 直接判型，其余列出主色与 gamma。
String _colorLabel(VideoParams vp) {
  final primaries = vp.primaries;
  final gamma = vp.gamma;
  if (gamma == 'pq') return primaries == 'bt.2020' ? 'HDR10' : 'HDR10（PQ）';
  if (gamma == 'arib-std-b67') return 'HLG';
  final parts = [
    if (primaries != null && primaries != 'unknown')
      _primariesNames[primaries] ?? primaries,
    if (gamma != null && gamma != 'unknown') _gammaNames[gamma] ?? gamma,
  ];
  return parts.join(' / ');
}

const _primariesNames = {
  'bt.601': 'BT.601',
  'bt.709': 'BT.709',
  'bt.2020': 'BT.2020',
  'dcip3-d65': 'DCI-P3',
  'smpte2084': 'HDR10',
  'arib-std-b67': 'HLG',
};

const _gammaNames = {
  'srgb': 'sRGB',
  'pq': 'PQ',
  '2.2': 'gamma 2.2',
  '2.4': 'gamma 2.4',
};

String _hwdecLabel(String? v) {
  if (v == null || v.isEmpty || v == 'no' || v == 'disabled') return '软解';
  return '硬解（$v）';
}

String _fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(2)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
  return '$b B';
}

String _fmtBitrate(int bps) {
  if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(2)} Mbps';
  if (bps >= 1000) return '${(bps / 1000).toStringAsFixed(0)} kbps';
  return '$bps bps';
}

String _fmtFps(double fps) {
  var s = fps.toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return '$s fps';
}

String _fmtKhz(int hz) {
  var s = (hz / 1000).toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return '$s kHz';
}

String _fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _fmtDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}
