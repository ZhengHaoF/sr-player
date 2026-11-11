import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_store.dart';
import 'video_tile.dart';

/// 视频文件的通用操作：长按菜单 → 播放 / 重命名 / 删除。
/// 返回是否发生了文件系统变更（调用方据此刷新列表）。
Future<bool> showVideoActions(BuildContext context, VideoItem video) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(video.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${video.durationLabel}  ${video.sizeLabel}'),
            onTap: () => Navigator.pop(ctx),
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
  if (action == 'rename') return renameVideo(context, video);
  if (action == 'delete') return deleteVideo(context, video);
  return false;
}

/// 重命名视频文件。成功返回 true。
Future<bool> renameVideo(BuildContext context, VideoItem video) async {
  final ctrl = TextEditingController(text: video.name);
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '新文件名'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('确定')),
      ],
    ),
  );
  if (newName == null || newName.isEmpty || newName == video.name) return false;
  try {
    await File(video.path).rename('${video.folder}/$newName');
    await AppStore.removePosition(video.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已重命名为 $newName')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
    return false;
  }
}

/// 删除视频文件。成功返回 true。
Future<bool> deleteVideo(BuildContext context, VideoItem video) async {
  final ok = await confirmDialog(
    context,
    title: '删除视频',
    content: '确定删除「${video.name}」吗？此操作不可恢复。',
  );
  if (!ok) return false;
  try {
    final f = File(video.path);
    if (f.existsSync()) await f.delete();
    await AppStore.removeHistory(video.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
    return false;
  }
}
