# SR Player

Flutter 本地视频播放器，内置基于 **Anime4K GLSL 着色器**的三档超分辨率（关闭 / 性能 / 质量），配合完整的基础文件管理。

技术栈：Flutter + [media_kit](https://pub.dev/packages/media_kit)（libmpv）+ Anime4K GLSL + Riverpod。

## 功能

### 超分辨率（核心特性）
- **关闭**：不挂载着色器，功耗最低（默认）。
- **性能**：Anime4K CNN S/M 档 7 连着色器（Restore S/M + Upscale x2 S/M + AutoDownscalePre + Clamp_Highlights）。
- **质量**：Anime4K CNN VL 档 6 连着色器（Restore VL + Upscale x2 VL/M + AutoDownscalePre + Clamp_Highlights）。
- 实现链路：`assets/shaders/*.glsl` → 解包到应用缓存目录 → `NativePlayer.setProperty('glsl-shaders', ...)` **热挂载**，切档无需重启播放。
- 播放器内「画面设置」面板与「我的」页均可切换，全局记忆。

### 视频库（视频 Tab）
- MediaStore 扫描全部本地视频（时长 / 大小 / 修改时间 / 分辨率）。
- 缩略图（原生 `MediaStore.loadThumbnail`，兜底 `MediaMetadataRetriever` 抽帧）+ 内存缓存。
- 平铺网格 / 文件夹聚合两种视图，按时间 / 名称 / 大小排序。

### 文件管理（文件 Tab）
- **完整目录树浏览**：从存储根目录逐级进入任意目录，面包屑导航，懒加载。
- 视频文件带缩略图与时长角标，非视频文件灰显可见。
- **收藏文件夹**：★ 一键收藏，横滑收藏栏快速跳转。
- 重命名 / 删除 / 新建文件夹（`MANAGE_EXTERNAL_STORAGE` 下直接走 `dart:io`）。

### 播放器
- 断点续播（>5s 且 <95% 自动恢复）、播放记录（最近 100 条）。
- 倍速 0.5x~3.0x、方向切换、控制层锁定、沉浸式 UI。
- 同名字幕自动加载（mpv `sub-auto=fuzzy`）。

## 构建运行

```bash
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

要求：Flutter 3.44+ / AGP 9 / JDK 17。首次启动需授予「所有文件访问」权限。

## 工程说明

- 缩略图通过平台通道（`MainActivity.kt` 的 `sr_player/media`）在原生侧生成，未使用第三方缩略图插件（`video_thumbnail` 与 AGP 9/Gradle 9 不兼容：其构建脚本仍引用 `jcenter()`）。
- 播放记录 / 收藏 / 续播点以 JSON 存于 `shared_preferences`（v1 规模足够，避免引入数据库依赖）。
- `android/gradle.properties` 中 `kotlin.incremental=false`：规避 Kotlin 2.3 在 Windows 上的增量缓存文件锁问题。

## 已知限制

- 模拟器上 media_kit 检测到 x86 会强制软件渲染，超分着色器的实际画质/性能需在**真机**验证（模拟器仅能验证链路与 UI）。
- Anime4K 为动画线条设计，对真人影视观感提升有限。
- 质量档（VL CNN）在中低端手机上可能掉帧，默认档位为关闭。

## 许可

- 本项目代码：MIT。
- [Anime4K](https://github.com/bloc97/Anime4K)：着色器文件遵循其原始许可（MIT / Unlicense，见 `assets/shaders/LICENSE`）。
