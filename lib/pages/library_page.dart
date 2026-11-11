import 'package:flutter/material.dart';

import '../models.dart';
import '../services/media_store.dart';
import '../widgets/video_actions.dart';
import '../widgets/video_tile.dart';
import 'player_page.dart';

/// 视频 Tab：全部视频网格 / 文件夹聚合，支持排序与长按管理。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

enum _Sort { timeDesc, name, sizeDesc }

class _LibraryPageState extends State<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  List<VideoItem> _videos = [];
  bool _loading = true;
  bool _folderView = false;
  _Sort _sort = _Sort.timeDesc;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final videos = await MediaStoreService.listVideos();
    if (!mounted) return;
    setState(() {
      _videos = _applySort(videos);
      _loading = false;
    });
  }

  List<VideoItem> _applySort(List<VideoItem> input) {
    final list = [...input];
    switch (_sort) {
      case _Sort.timeDesc:
        list.sort((a, b) => b.modifiedSec.compareTo(a.modifiedSec));
      case _Sort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _Sort.sizeDesc:
        list.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    }
    return list;
  }

  Future<void> _manage(VideoItem v) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${v.durationLabel}  ${v.sizeLabel}'),
              onTap: () => Navigator.pop(ctx, 'play'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        if (await renameVideo(context, v)) _load();
      case 'delete':
        if (await deleteVideo(context, v)) _load();
    }
  }

  void _open(VideoItem v) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(path: v.path, title: v.name),
    )).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_folderView ? '文件夹' : '全部视频'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _folderView = !_folderView),
            icon: Icon(_folderView ? Icons.grid_view : Icons.folder_copy_outlined),
            tooltip: _folderView ? '平铺视图' : '文件夹视图',
          ),
          PopupMenuButton<_Sort>(
            icon: const Icon(Icons.sort),
            tooltip: '排序',
            onSelected: (s) => setState(() {
              _sort = s;
              _videos = _applySort(_videos);
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Sort.timeDesc, child: Text('按时间')),
              PopupMenuItem(value: _Sort.name, child: Text('按名称')),
              PopupMenuItem(value: _Sort.sizeDesc, child: Text('按大小')),
            ],
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: '刷新'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _videos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.video_library_outlined, size: 64, color: Colors.grey[500]),
                      const SizedBox(height: 12),
                      Text('未找到视频文件', style: TextStyle(color: Colors.grey[600])),
                      TextButton(onPressed: _load, child: const Text('重新扫描')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _folderView ? _buildFolders() : _buildGrid(),
                ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.92,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: _videos.length,
      itemBuilder: (_, i) {
        final v = _videos[i];
        return VideoTile(
          path: v.path,
          title: v.name,
          contentUri: v.contentUri,
          duration: v.durationLabel,
          subtitle: '${v.sizeLabel}  ·  ${v.folder.split('/').last}',
          onTap: () => _open(v),
          onLongPress: () => _manage(v),
        );
      },
    );
  }

  Widget _buildFolders() {
    final groups = <String, List<VideoItem>>{};
    for (final v in _videos) {
      groups.putIfAbsent(v.folder, () => []).add(v);
    }
    final folders = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.separated(
      itemCount: folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final folder = folders[i];
        final items = groups[folder]!;
        return ListTile(
          leading: const Icon(Icons.folder, color: Colors.amber, size: 36),
          title: Text(folder.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${items.length} 个视频  ·  $folder',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _FolderDetailPage(folder: folder, videos: items),
            )).then((_) => _load());
          },
        );
      },
    );
  }
}

class _FolderDetailPage extends StatelessWidget {
  final String folder;
  final List<VideoItem> videos;

  const _FolderDetailPage({required this.folder, required this.videos});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(folder.split('/').last)),
      body: ListView.builder(
        itemCount: videos.length,
        itemBuilder: (_, i) {
          final v = videos[i];
          return ListTile(
            leading: const Icon(Icons.play_circle_outline, size: 40),
            title: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${v.durationLabel}  ${v.sizeLabel}'),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlayerPage(path: v.path, title: v.name),
              ));
            },
            onLongPress: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlayerPage(path: v.path, title: v.name),
              ));
            },
          );
        },
      ),
    );
  }
}
