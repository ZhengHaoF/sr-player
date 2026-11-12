import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../services/app_store.dart';
import '../services/fs.dart';
import '../state.dart';
import '../widgets/video_actions.dart';
import '../widgets/video_tile.dart';
import 'player_page.dart';

/// 文件 Tab：完整目录树浏览（懒加载、面包屑、收藏文件夹）。
class FilesPage extends ConsumerStatefulWidget {
  /// 可选的起始路径（收藏跳转用）。
  final String? initialPath;

  const FilesPage({super.key, this.initialPath});

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage>
    with AutomaticKeepAliveClientMixin {
  List<FileSystemEntity> _entries = [];
  bool _loading = true;
  String _error = '';
  int _favVersion = 0;

  /// 主存储根目录（异步确认前用常见路径兜底）。
  String get _root =>
      ref.read(storageRootProvider).value ?? FsService.fallbackRoot;

  @override
  bool get wantKeepAlive => true;

  String get _path => ref.read(currentPathProvider);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPath;
    if (initial != null && initial.isNotEmpty) {
      ref.read(currentPathProvider.notifier).set(initial);
    }
    // 路径变化（目录跳转/返回回退）时重新加载目录。
    ref.listenManual(currentPathProvider, (prev, next) {
      if (prev != next) _load();
    });
    // 根目录异步确认后，若当前路径不在根目录内（旧状态/异常），拉回根目录。
    ref.listenManual(storageRootProvider, (prev, next) {
      final root = next.value;
      if (root == null || root.isEmpty) return;
      final current = _path;
      if (current != root && !current.startsWith('$root/')) {
        ref.read(currentPathProvider.notifier).set(root);
      }
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final current = _path;
    try {
      final entries = await FsService.listDir(current);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 无权限目录自动救回：回到主存储根目录，避免用户卡死在死区。
      final isPermissionError =
          e is PathAccessException || e.toString().contains('Permission denied');
      if (isPermissionError && current != _root) {
        // set 会触发 currentPathProvider 监听，自动重新加载根目录。
        ref.read(currentPathProvider.notifier).set(_root);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该目录无访问权限，已回到根目录'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      setState(() {
        _loading = false;
        _error = '无法读取该目录：$e';
      });
    }
  }

  void _enter(String path) {
    // 只允许在主存储根目录之内浏览，防止进入 /storage 等无权限目录。
    if (path != _root && !path.startsWith('$_root/')) return;
    // 设置路径即可：currentPathProvider 监听器会触发重新加载。
    ref.read(currentPathProvider.notifier).set(path);
  }

  Future<void> _toggleFav() async {
    await AppStore.toggleFavorite(_path);
    setState(() => _favVersion++);
  }

  Future<void> _folderAction() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(AppStore.isFavorite(_path)
                  ? Icons.star
                  : Icons.star_border),
              title: Text(AppStore.isFavorite(_path) ? '取消收藏该文件夹' : '收藏该文件夹'),
              onTap: () => Navigator.pop(ctx, 'fav'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建文件夹'),
              onTap: () => Navigator.pop(ctx, 'mkdir'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'fav') {
      await _toggleFav();
    } else if (action == 'mkdir') {
      await _mkdir();
    }
  }

  Future<void> _mkdir() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await Directory('$_path/$name').create();
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 使用 watch：路径/根目录变化时自动重建（返回回退后界面自动刷新）。
    final path = ref.watch(currentPathProvider);
    final root =
        ref.watch(storageRootProvider).value ?? FsService.fallbackRoot;
    final crumbs = FsService.breadcrumbs(path, root: root);
    final isFav = AppStore.isFavorite(path);
    final favs = AppStore.favorites;

    // 返回键由 HomePage 统一处理（文件子目录回退 / 根目录双击退出）。
    // 本页不再挂载 PopScope，避免与全局返回拦截双重触发。
    return Scaffold(
        appBar: AppBar(
          title: Text(path.split('/').last, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: isFav ? '取消收藏' : '收藏此文件夹',
              onPressed: _toggleFav,
              icon: Icon(isFav ? Icons.star : Icons.star_border, color: isFav ? Colors.amber : null),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.small(
          heroTag: 'files-actions',
          onPressed: _folderAction,
          child: const Icon(Icons.more_vert),
        ),
        body: Column(
          children: [
            // 收藏栏。
            if (favs.isNotEmpty)
              SizedBox(
                key: ValueKey('favs-$_favVersion'),
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  children: [
                    for (final f in favs)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          avatar: const Icon(Icons.star, size: 16, color: Colors.amber),
                          label: Text(FsService.fileNameOf(f), style: const TextStyle(fontSize: 12)),
                          onPressed: () => _enter(f),
                          onDeleted: () async {
                            await AppStore.toggleFavorite(f);
                            setState(() => _favVersion++);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            // 面包屑。
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  for (final (name, fullPath) in crumbs)
                    Row(children: [
                      InkWell(
                        onTap: () => _enter(fullPath),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 13,
                              color: fullPath == _path
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey[600],
                              fontWeight: fullPath == _path ? FontWeight.bold : null,
                            ),
                          ),
                        ),
                      ),
                      if (fullPath != _path)
                        Icon(Icons.chevron_right, size: 16, color: Colors.grey[500]),
                    ]),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 56, color: Colors.grey[500]),
            const SizedBox(height: 8),
            Text(_error, style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(child: Text('空目录', style: TextStyle(color: Colors.grey[600])));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (_, i) => _buildRow(_entries[i]),
      ),
    );
  }

  Widget _buildRow(FileSystemEntity e) {
    final path = e.path;
    final name = FsService.fileNameOf(path);
    final hidden = name.startsWith('.');

    if (e is Directory) {
      return ListTile(
        leading: Icon(Icons.folder, color: Colors.amber.shade600, size: 32),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: hidden ? const TextStyle(color: Colors.grey) : null),
        onTap: () => _enter(path),
        onLongPress: () => _enter(path),
        trailing: const Icon(Icons.chevron_right, size: 20),
      );
    }

    final isVideo = isVideoPath(path);
    if (!isVideo) {
      return ListTile(
        leading: Icon(Icons.insert_drive_file_outlined, color: Colors.grey[500], size: 28),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        dense: true,
      );
    }

    return VideoTile(
      path: path,
      title: name,
      listMode: true,
      onTap: () {
        Navigator.of(context)
            .push(MaterialPageRoute(
          builder: (_) => PlayerPage.local(path, title: name),
        ))
            .then((_) => _load());
      },
      onLongPress: () async {
        final changed = await showVideoActions(
          context,
          VideoItem(path: path, name: name),
        );
        if (changed) _load();
      },
    );
  }
}
