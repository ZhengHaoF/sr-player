import 'package:flutter_test/flutter_test.dart';

import 'package:sr_player/models.dart';
import 'package:sr_player/services/shader_service.dart';

void main() {
  test('SR 档位与着色器链定义', () {
    expect(SrMode.values.length, 5);
    expect(ShaderService.chainFor(SrMode.off), isEmpty);
    expect(ShaderService.performanceChain.length, 7);
    expect(ShaderService.qualityChain.length, 6);
    // 两档共用 Clamp_Highlights，且文件名都指向 assets/shaders 下的真实资产。
    expect(
      ShaderService.performanceChain.first,
      'Anime4K_Clamp_Highlights.glsl',
    );
    expect(ShaderService.qualityChain[1], 'Anime4K_Restore_CNN_VL.glsl');
    // 极致档 = 质量链全量 + 二段 Restore_CNN_S 收尾。
    expect(ShaderService.ultraChain.take(6), ShaderService.qualityChain);
    expect(ShaderService.ultraChain.last, 'Anime4K_Restore_CNN_S.glsl');
    // 实验档：单个 ArtCNN compute shader，需 vo=gpu-next。
    expect(ShaderService.chainFor(SrMode.experimental), [
      'ArtCNN_C4F32_DS.glsl',
    ]);
    // 平台可用性（测试宿主为桌面端）：极致档仅桌面，实验档仅 Android。
    expect(SrMode.ultra.platformAvailable, isTrue);
    expect(SrMode.experimental.platformAvailable, isFalse);
  });

  test('视频扩展名识别', () {
    expect(isVideoPath('/a/b/c.MP4'), isTrue);
    expect(isVideoPath('/a/b/c.mkv'), isTrue);
    expect(isVideoPath('/a/b/c.txt'), isFalse);
    expect(isVideoPath('/a/b/noext'), isFalse);
  });
}
