import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'fs.dart';

/// Anime4K GLSL 着色器管理。
///
/// mpv 是 native 进程，读不到 Flutter asset，因此把 GLSL 从 assets
/// 解包到应用缓存目录，再把真实文件路径交给 mpv 的 `glsl-shaders` 属性。
/// 字节缓存避免每次切档都重复读盘。
class ShaderService {
  ShaderService._();

  static const String _assetPrefix = 'assets/shaders/';
  static const String _cacheDirName = 'anime4k_shaders';

  /// 内存字节缓存：文件名 → 内容。
  static final Map<String, Uint8List> _bytes = {};

  /// 本地路径缓存：文件名 → 落地后的绝对路径。
  static final Map<String, String> _paths = {};

  /// 性能档（对应 Anime4K Mode C 思路，7 个 S/M 档 CNN）。
  static const List<String> performanceChain = [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Restore_CNN_S.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
  ];

  /// 质量档（对应 Anime4K Mode A+B 思路，6 个 VL 档 CNN）。
  static const List<String> qualityChain = [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ];

  /// 实验档（ArtCNN v1.6.2，单 compute shader，需 mpv vo=gpu-next）。
  /// 注意：media_kit 在 Android 把渲染面固定为视频原始分辨率，官方版的
  /// `//!WHEN 输出>1.3x源` 守卫永不满足，因此打包的是去掉守卫的版本——
  /// CNN 在源分辨率运行，去噪+锐化生效；真正放大需待渲染面尺寸修复。
  static const List<String> experimentalChain = [
    'ArtCNN_C4F32_DS.glsl',
  ];

  /// 当前打包的 libmpv 是否含 gpu-next(libplacebo) 渲染器。
  ///
  /// media-kit 预编译库（≤v1.1.11 全部变体）不含 gpu-next；现已改用
  /// Predidit/libmpv-android-video-build v1.3.1 的 libmpv.so（jniLibs 覆盖，
  /// 见 android/app/build.gradle.kts 的 pickFirst），实验档解锁。
  /// 已知限制：MuMu 模拟器显译层不执行 compute shader（无报错但无效果），
  /// 真机待复测。
  static const bool gpuNextAvailable = true;

  static List<String> chainFor(SrMode mode) => switch (mode) {
        SrMode.off => const [],
        SrMode.performance => performanceChain,
        SrMode.quality => qualityChain,
        SrMode.experimental => experimentalChain,
      };

  /// 解析某档位全部着色器的本地路径（保证已落地到缓存目录）。
  static Future<List<String>> resolveChain(SrMode mode) async {
    final names = chainFor(mode);
    if (names.isEmpty) return const [];

    final root = await getTemporaryDirectory();
    final dir = Directory('${root.path}/$_cacheDirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final result = <String>[];
    for (final name in names) {
      // 归一化为 '/' 分隔，交给 mpv 时 Windows/Android 表现一致。
      result.add(FsService.normalizePath(await _ensureFile(dir, name)));
    }
    return result;
  }

  static Future<String> _ensureFile(Directory dir, String name) async {
    final cached = _paths[name];
    if (cached != null && File(cached).existsSync()) return cached;

    final bytes = await _loadBytes(name);
    final file = File('${dir.path}/$name');
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    _paths[name] = file.path;
    return file.path;
  }

  static Future<Uint8List> _loadBytes(String name) async {
    final hit = _bytes[name];
    if (hit != null) return hit;
    final data = await rootBundle.load('$_assetPrefix$name');
    final bytes = data.buffer.asUint8List();
    _bytes[name] = bytes;
    return bytes;
  }

  /// 清空缓存（设置页"清除着色器缓存"用）。
  static void clearMemoryCache() {
    _bytes.clear();
    _paths.clear();
  }
}
