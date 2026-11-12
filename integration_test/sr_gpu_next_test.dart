import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

/// gpu-next 实验档集成验证（真机/模拟器上运行）：
///
/// 1. 创建时挂 gpu-next（VideoControllerConfiguration 路径，PlayerPage 同款）；
/// 2. 播放本地视频，断言 current-vo == `gpu-next`、画面推进；
/// 3. 挂载 ArtCNN_C4F32_DS.glsl（compute shader）无错误；
/// 4. 运行时切回 gpu + Anime4K 性能链挂载，验证经典渲染器未回归。
///
/// 运行：`flutter test integration_test -d <device>`
/// 前置：/sdcard/Download/sr_test.mp4 已推送（见 README 或 CI 脚本）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final errors = <String>[];

  testWidgets('实验档：gpu-next + ArtCNN compute shader', (tester) async {
    final video = File('/sdcard/Download/sr_test.mp4');
    if (!video.existsSync()) {
      fail('缺少测试视频 /sdcard/Download/sr_test.mp4（adb push 63KB 静态测试片）');
    }

    final dir = (await getTemporaryDirectory()).path;
    final shader = File('$dir/artcnn_it.glsl');
    final data = await rootBundle.load('assets/shaders/ArtCNN_C4F32_DS.glsl');
    await shader.writeAsBytes(data.buffer.asUint8List(), flush: true);

    final player = Player(
      configuration: const PlayerConfiguration(vo: 'gpu-next'),
    );
    // 与 PlayerPage 一致：Android 控制器的 vo 覆盖 PlayerConfiguration。
    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        vo: 'gpu-next',
        width: 1920,
        height: 1080,
      ),
    );
    expect(controller, isNotNull);
    addTearDown(player.dispose);
    // 收集 vo 相关致命错误，供断言。
    player.stream.log.listen((e) {
      if (e.level == 'fatal' ||
          (e.level == 'error' && (e.prefix == 'vo' || e.prefix.startsWith('vo/')))) {
        errors.add('${e.prefix}: ${e.text}');
      }
    });

    final platform = player.platform as NativePlayer;
    await platform.setProperty('glsl-shaders', shader.path);
    await player.open(Media(video.path));
    await player.play();

    // 等待 vo 初始化与播放推进。
    await Future<void>.delayed(const Duration(seconds: 4));

    final currentVo = await platform.getProperty('current-vo');
    expect(currentVo, 'gpu-next', reason: 'gpu-next 渲染器应实际生效');

    expect(player.state.playing, isTrue, reason: '视频应处于播放状态');
    expect(
      player.state.position.inMilliseconds,
      greaterThan(0),
      reason: '播放位置应推进（vo 初始化失败时视频通道会卡死）',
    );

    expect(errors.where((e) => e.contains('gpu-next')), isEmpty,
        reason: '不应出现 gpu-next 相关 fatal（缺 libplacebo / 上下文失败等）');

    // 挂载的 shader 保持生效。
    final glsl = await platform.getProperty('glsl-shaders');
    expect(glsl, contains('artcnn_it.glsl'));

    // 运行时切回 gpu + Anime4K 性能链（经典渲染器回归验证）。
    await platform.setProperty('glsl-shaders', '');
    await platform.setProperty('vo', 'gpu');
    await Future<void>.delayed(const Duration(seconds: 2));
    final voBack = await platform.getProperty('current-vo');
    expect(voBack, 'gpu', reason: '应能切回经典渲染器');

    // 忽略测试自身清理前的瞬时状态。
    errors.clear();
    // Anime4K 性能链挂载（vo=gpu 上运行，验证新内核下经典路径未回归）。
    const perfChain = [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Restore_CNN_S.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ];
    for (final name in perfChain) {
      final f = File('$dir/$name');
      final d = await rootBundle.load('assets/shaders/$name');
      await f.writeAsBytes(d.buffer.asUint8List(), flush: true);
    }
    await platform.setProperty('glsl-shaders', perfChain.join(':'));
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(errors, isEmpty, reason: 'Anime4K 性能链在经典渲染器上不应报错: $errors');
    expect(player.state.playing, isTrue, reason: '切回 gpu + Anime4K 后应继续播放');
  });
}
