import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/fs.dart';

/// 视频缩略图卡片。
/// - grid 模式（默认）：16:9 图 + 时长角标 + 标题/大小，用于 GridView；
/// - listMode：固定高度行，用于 ListView（无界高度约束下 Expanded 会崩）。
class VideoTile extends StatelessWidget {
  final String path;
  final String title;
  final String? contentUri;
  final String? duration;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool listMode;

  const VideoTile({
    super.key,
    required this.path,
    required this.title,
    this.contentUri,
    this.duration,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.listMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final tile = listMode ? _buildList(context) : _buildGrid(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: tile,
    );
  }

  Widget _buildList(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Row(
        children: [
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            height: 54,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumb(path: path, contentUri: contentUri),
                  if (duration != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        color: Colors.black54,
                        child: Text(duration!,
                            style: const TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ],
            ),
          ),
          if (trailing != null) trailing!,
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Thumb(path: path, contentUri: contentUri),
                if (duration != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        duration!,
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ],
    );
  }
}

class _Thumb extends StatefulWidget {
  final String path;
  final String? contentUri;
  const _Thumb({required this.path, this.contentUri});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = ThumbCache.getSync(widget.path);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }
    final b = await ThumbCache.get(widget.path, contentUri: widget.contentUri);
    if (mounted) {
      setState(() {
        _bytes = b;
        _failed = b == null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return Container(
      color: Colors.grey[900],
      alignment: Alignment.center,
      child: _failed
          ? Icon(Icons.videocam_outlined, color: Colors.grey[600])
          : const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

/// 通用确认弹窗，返回 true 表示确认。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '删除',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return ok == true;
}
