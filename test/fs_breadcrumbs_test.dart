import 'package:flutter_test/flutter_test.dart';
import 'package:sr_player/services/fs.dart';

void main() {
  group('FsService.breadcrumbs 根目录限制', () {
    test('不带 root 时返回完整层级', () {
      final crumbs = FsService.breadcrumbs('/storage/emulated/0/Movies');
      expect(crumbs.map((c) => c.$1).toList(),
          ['storage', 'emulated', '0', 'Movies']);
      expect(crumbs.map((c) => c.$2).toList(), [
        '/storage',
        '/storage/emulated',
        '/storage/emulated/0',
        '/storage/emulated/0/Movies',
      ]);
    });

    test('带 root 时只显示根目录及其子级', () {
      final crumbs = FsService.breadcrumbs('/storage/emulated/0/Movies',
          root: '/storage/emulated/0');
      expect(crumbs.map((c) => c.$1).toList(), ['0', 'Movies']);
      expect(crumbs.map((c) => c.$2).toList(),
          ['/storage/emulated/0', '/storage/emulated/0/Movies']);
    });

    test('根目录本身只显示一级', () {
      final crumbs =
          FsService.breadcrumbs('/storage/emulated/0', root: '/storage/emulated/0');
      expect(crumbs.map((c) => c.$1).toList(), ['0']);
    });

    test('root 之外的路径不产生面包屑（防御无权限目录）', () {
      final crumbs = FsService.breadcrumbs('/storage', root: '/storage/emulated/0');
      expect(crumbs, isEmpty);
    });
  });
}