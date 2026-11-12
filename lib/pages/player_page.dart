import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models.dart';
import '../services/app_store.dart';
import '../services/shader_service.dart';
import '../state.dart';

/// 视频播放页：media_kit(libmpv) + Anime4K GLSL 超分三档热切换。
class PlayerPage extends ConsumerStatefulWidget {
  final String path;
  final String title;

  const PlayerPage({super.key, required this.path, required this.title});

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

  // 方向偏好循环：自动 → 横屏 → 竖屏。
  int _orientation = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _player = Player();
    _controller = VideoController(_player);
    _posSub = _player.stream.position
        .where((_) => _ready)
        .distinct()
        .listen((pos) => _savePosition(pos));
    _open();
  }

  Future<void> _open() async {
    try {
      // 同名字幕自动加载（mpv 原生能力）。
      final platform0 = _player.platform;
      if (platform0 is NativePlayer) {
        await platform0.setProperty('sub-auto', 'fuzzy');
      }
      final saved = AppStore.getPosition(widget.path);
      final durMs = (saved?['dur'] as num?)?.toInt() ?? 0;
      final posMs = (saved?['pos'] as num?)?.toInt() ?? 0;
      await _player.open(Media(widget.path));
      // >5s 且未看完（<95%）则续播。
      if (posMs > 5000 && (durMs <= 0 || posMs < durMs * 0.95)) {
        await _player.seek(Duration(milliseconds: posMs));
      }
      await _player.play();
      // 应用当前 SR 档位。
      await _applySr(ref.read(srModeProvider), notify: false);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 切换超分档位：解析 shader → setProperty 热挂载，无需重建播放器。
  Future<void> _applySr(SrMode mode, {bool notify = true}) async {
    try {
      final paths = await ShaderService.resolveChain(mode);
      final platform = _player.platform;
      if (platform is NativePlayer) {
        // glsl-shaders 是 mpv 的路径列表选项：分隔符在 Unix/Android 上是 ':'（Windows 为 ';'），
        // 用 ',' 会被当成一个整体路径，导致 Cannot open file、shader 静默不挂载。
        await platform.setProperty('glsl-shaders', paths.join(':'));
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

  void _savePosition(Duration pos) {
    final dur = _player.state.duration.inMilliseconds;
    final p = pos.inMilliseconds;
    if (p <= 0 || (dur > 0 && p >= dur * 0.95)) return;
    AppStore.recordPlayback(path: widget.path, name: widget.title, posMs: p, durMs: dur);
  }

  @override
  void dispose() {
    final dur = _player.state.duration.inMilliseconds;
    final pos = _player.state.position.inMilliseconds;
    if (pos > 0 && (dur <= 0 || pos < dur * 0.95)) {
      AppStore.recordPlayback(path: widget.path, name: widget.title, posMs: pos, durMs: dur);
    }
    _posSub?.cancel();
    _hideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 强制恢复竖屏：主界面（视频库/文件/我的）均为竖屏设计，
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
                  '基于 Anime4K GLSL 着色器，热切换无需重启播放。',
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
          child: Text(_error, style: const TextStyle(color: Colors.white70)),
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
                  widget.title,
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
