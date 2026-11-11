import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/app_store.dart';
import '../services/fs.dart';
import '../state.dart';
import 'files_page.dart';
import 'player_page.dart';

/// 我的 Tab：播放记录 / 收藏文件夹 / 设置。
class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key});

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final srMode = ref.watch(srModeProvider);

    return ListView(
      children: [
        const _SectionHeader('观看'),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('播放记录'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const HistoryPage())),
        ),
        ListTile(
          leading: const Icon(Icons.star_border),
          title: const Text('收藏的文件夹'),
          subtitle: Text('${AppStore.favorites.length} 个'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const FavoritesPage())),
        ),
        const _SectionHeader('画面'),
        for (final m in SrMode.values)
          RadioListTile<SrMode>(
            value: m,
            groupValue: srMode,
            onChanged: (v) {
              if (v != null) ref.read(srModeProvider.notifier).set(v);
            },
            title: Text(m == SrMode.off ? '关闭超分辨率' : '超分辨率：${m.label}'),
            subtitle: Text(m.desc, style: const TextStyle(fontSize: 12)),
            secondary: const Icon(Icons.auto_awesome_outlined),
          ),
        const _SectionHeader('文件'),
        SwitchListTile(
          secondary: const Icon(Icons.visibility_outlined),
          title: const Text('显示隐藏文件/目录'),
          value: AppStore.showHidden,
          onChanged: (v) async {
            await AppStore.setShowHidden(v);
            setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('清除缩略图缓存'),
          onTap: () {
            ThumbCache.clearMemory();
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('缩略图缓存已清除')));
          },
        ),
        const _SectionHeader('关于'),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('SR Player'),
          subtitle: Text('Flutter + media_kit(libmpv) + Anime4K GLSL\n超分辨率着色器遵循 MIT / Unlicense 许可。'),
          isThreeLine: true,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[600])),
    );
  }
}

/// 播放记录页。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final list = AppStore.history();
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放记录'),
        actions: [
          if (list.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                await AppStore.clearHistory();
                (context as Element).markNeedsBuild();
              },
            ),
        ],
      ),
      body: list.isEmpty
          ? const Center(child: Text('暂无播放记录'))
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = list[i];
                final path = e['path'] as String;
                final name = (e['name'] as String?) ?? path;
                final posMs = (e['pos'] as num?)?.toInt() ?? 0;
                final durMs = (e['dur'] as num?)?.toInt() ?? 0;
                final pct = durMs > 0 ? (posMs / durMs * 100).clamp(0, 100).toStringAsFixed(0) : '0';
                final updated = (e['updated'] as num?)?.toInt() ?? 0;
                final dt = DateTime.fromMillisecondsSinceEpoch(updated);
                return ListTile(
                  leading: const Icon(Icons.play_circle_outline, size: 36),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('看到 $pct% · ${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}'),
                  onTap: () {
                    if (File(path).existsSync()) {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => PlayerPage(path: path, title: name)));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('文件不存在')));
                    }
                  },
                  onLongPress: () async {
                    await AppStore.removeHistory(path);
                    (context as Element).markNeedsBuild();
                  },
                );
              },
            ),
    );
  }
}

/// 收藏文件夹管理页。
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final favs = AppStore.favorites;
    return Scaffold(
      appBar: AppBar(title: const Text('收藏的文件夹')),
      body: favs.isEmpty
          ? const Center(child: Text('暂无收藏，去「文件」页长按或点 ★ 收藏'))
          : ListView.separated(
              itemCount: favs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final f = favs[i];
                return ListTile(
                  leading: const Icon(Icons.folder, color: Colors.amber),
                  title: Text(FsService.fileNameOf(f)),
                  subtitle: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => FilesPage(initialPath: f),
                    ));
                  },
                );
              },
            ),
    );
  }
}
