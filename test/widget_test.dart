import 'package:flutter_test/flutter_test.dart';

import 'package:sr_player/models.dart';
import 'package:sr_player/services/shader_service.dart';

void main() {
  test('SR 档位与着色器链定义', () {
    expect(SrMode.values.length, 3);
    expect(ShaderService.chainFor(SrMode.off), isEmpty);
    expect(ShaderService.performanceChain.length, 7);
    expect(ShaderService.qualityChain.length, 6);
    // 两档共用 Clamp_Highlights，且文件名都指向 assets/shaders 下的真实资产。
    expect(ShaderService.performanceChain.first, 'Anime4K_Clamp_Highlights.glsl');
    expect(ShaderService.qualityChain[1], 'Anime4K_Restore_CNN_VL.glsl');
  });

  test('视频扩展名识别', () {
    expect(isVideoPath('/a/b/c.MP4'), isTrue);
    expect(isVideoPath('/a/b/c.mkv'), isTrue);
    expect(isVideoPath('/a/b/c.txt'), isFalse);
    expect(isVideoPath('/a/b/noext'), isFalse);
  });
}
