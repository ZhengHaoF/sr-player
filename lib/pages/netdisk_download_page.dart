import 'package:flutter/material.dart';

import '../services/netdisk/download_service.dart';
import 'player_page.dart';

/// 下载管理页：任务进度、暂停/续传/重试/删除，完成后点击本地播放。
class NetdiskDownloadPage extends StatefulWidget {
  const NetdiskDownloadPage({super.key});

  @override
  State<NetdiskDownloadPage> createState() => _NetdiskDownloadPageState();
}

class _NetdiskDownloadPageState extends State<NetdiskDownloadPage> {
  final DownloadService _svc = DownloadService.instance;

  @override
  void initState() {
    super.initState();
    _svc.ensureLoaded();
    _svc.addListener(_onChanged);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmRemove(DownloadTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载任务'),
        content: Text(
          t.status == DownloadStatus.done
              ? '将同时删除已下载的本地文件「${t.name}」。'
              : '将删除任务「${t.name}」${t.receivedBytes > 0 ? '及已下载的部分文件' : ''}。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _svc.remove(t.id);
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _svc.tasks;
    return Scaffold(
      appBar: AppBar(title: const Text('下载管理')),
      body: tasks.isEmpty
          ? const Center(
              child: Text(
                '暂无下载任务\n在网盘视频条目上点下载图标加入队列',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (_, i) => _buildRow(tasks[i]),
            ),
    );
  }

  Widget _buildRow(DownloadTask t) {
    final canPlay = t.status == DownloadStatus.done && t.localPath != null;
    return ListTile(
      leading: Icon(
        t.status == DownloadStatus.done
            ? Icons.download_done_outlined
            : Icons.downloading_outlined,
        color: t.status == DownloadStatus.failed
            ? Colors.red.shade300
            : t.status == DownloadStatus.done
                ? Colors.green.shade400
                : Colors.indigo.shade300,
        size: 30,
      ),
      title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            _statusText(t),
            style: TextStyle(
              fontSize: 11,
              color: t.status == DownloadStatus.failed
                  ? Colors.red.shade400
                  : Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: t.totalBytes > 0 ? t.receivedBytes / t.totalBytes : null,
              minHeight: 4,
              backgroundColor: Colors.grey.shade200,
            ),
          ),
        ],
      ),
      trailing: _buildActions(t),
      onTap: () {
        if (canPlay) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PlayerPage.local(t.localPath!, title: t.name),
          ));
        } else if (t.status == DownloadStatus.failed) {
          _svc.resume(t.id); // 失败一键重试
        }
      },
    );
  }

  String _statusText(DownloadTask t) {
    final progress =
        '${_fmtSize(t.receivedBytes)} / ${t.totalBytes > 0 ? _fmtSize(t.totalBytes) : '未知大小'}';
    return switch (t.status) {
      DownloadStatus.queued => '排队中 · $progress',
      DownloadStatus.running => '下载中 · $progress',
      DownloadStatus.paused => '已暂停 · $progress',
      DownloadStatus.done => '已完成 · ${_fmtSize(t.totalBytes)}',
      DownloadStatus.failed =>
        '${t.error ?? '失败'} · 已下载 ${_fmtSize(t.receivedBytes)}',
    };
  }

  Widget _buildActions(DownloadTask t) {
    final children = <Widget>[];
    switch (t.status) {
      case DownloadStatus.running:
        children.add(IconButton(
          tooltip: '暂停',
          onPressed: () => _svc.pause(t.id),
          icon: const Icon(Icons.pause_circle_outline),
        ));
      case DownloadStatus.queued:
        children.add(const SizedBox(width: 34));
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        children.add(IconButton(
          tooltip: t.status == DownloadStatus.failed ? '重试' : '继续',
          onPressed: () => _svc.resume(t.id),
          icon: Icon(
            t.status == DownloadStatus.failed
                ? Icons.refresh
                : Icons.play_circle_outline,
          ),
        ));
      case DownloadStatus.done:
        break;
    }
    children.add(IconButton(
      tooltip: '删除',
      onPressed: () => _confirmRemove(t),
      icon: const Icon(Icons.delete_outline, size: 22),
    ));
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
