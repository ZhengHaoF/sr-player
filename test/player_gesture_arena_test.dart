// 复现 player_page.dart 的手势层叠结构，验证手势竞技场机制：
//
// Bug 1 前提：Video 默认 controls=AdaptiveVideoControls，与自定义控制层叠加 → 双控制条。
// Bug 2 机制：全屏半透明 GestureDetector(translucent) 叠在 Video 上方，
//            点 media_kit 内置中央暂停按钮时，外层 onTap 抢走手势 → 暂停无效。
//
// 测试 1：当前结构（按钮在下层、全屏 translucent onTap 在上层）→ 预期 RED
// 测试 2：修复后结构（按钮在 overlay 子树内，即 NoVideoControls 后只剩自定义按钮）→ 预期 GREEN
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mechanism: overlay above built-in button steals the tap → must use NoVideoControls',
      (tester) async {
    var overlayTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // 模拟 media_kit 内置控制层的中央暂停按钮（位于 Video 内）。
            Center(
              child: IconButton(
                key: const Key('builtin-pause'),
                icon: const Icon(Icons.pause_circle_outline),
                onPressed: () => buttonTaps++,
              ),
            ),
            // 模拟自定义全屏控制层（player_page.dart 原样：translucent + onTap 切换）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => overlayTaps++,
                child: IgnorePointer(
                  ignoring: false,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('builtin-pause')));
    await tester.pumpAndSettle();

    // 固化 Flutter 手势竞技场机制：上层 translucent onTap 抢走下层按钮的点击。
    // 这就是播放页必须 Video(controls: NoVideoControls) 的原因 ——
    // 一旦 media_kit 内置控制层与自定义控制层叠放，内置暂停按钮必然失灵。
    expect(buttonTaps, 0, reason: '上层 overlay 必然抢走下层按钮的点击（竞技场先加入者胜）');
    expect(overlayTaps, 1, reason: '点击实际落在 overlay 的 onTap 上');
  });

  testWidgets('fix: custom play button inside overlay subtree wins the arena',
      (tester) async {
    var overlayTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // NoVideoControls 后，唯一可点的按钮在 overlay 子树内（_StreamPlayButton）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => overlayTaps++,
                child: IgnorePointer(
                  ignoring: false,
                  child: Center(
                    child: IconButton(
                      key: const Key('custom-play'),
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: () => buttonTaps++,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('custom-play')));
    await tester.pumpAndSettle();

    expect(buttonTaps, 1, reason: '自定义播放/暂停按钮应正常收到点击');
    expect(overlayTaps, 0, reason: '点按钮不应触发控制层整体切换');
  });
}
