import 'dart:async';

import 'package:flutter/material.dart';

import '../services/netdisk/baidu_api.dart';
import '../services/netdisk/play_source.dart';
import 'player_page.dart';

/// 云盘搜索页（手册 A.7）：关键词搜索全盘视频，点击在线播放。
/// 防抖 300ms + 单飞行（过期响应按序号作废）；key 上限 30 字符为接口限制。
class NetdiskSearchPage extends StatefulWidget {
  const NetdiskSearchPage({super.key});

  @override
  State<NetdiskSearchPage> createState() => _NetdiskSearchPageState();
}

class _NetdiskSearchPageState extends State<NetdiskSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _reqSeq = 0; // 单飞行序号：只接受最新一次请求的响应
  bool _loading = false;
  bool _hasMore = false; // 接口暂无翻页参数，仅用于提示
  String _error = '';
  List<CloudEntry> _results = const [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() {
        _results = const [];
        _hasMore = false;
        _error = '';
        _loading = false;
      });
      return;
    }
    setState(() {}); // 同步刷新清空按钮显隐
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(key));
  }

  Future<void> _search(String key) async {
    final seq = ++_reqSeq;
    setState(() => _loading = true);
    try {
      final (entries, hasMore) = await BaiduApi.search(key);
      if (!mounted || seq != _reqSeq) return; // 过期响应作废
      setState(() {
        _results = entries;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 搜索结果跨目录，展示所在目录便于区分同名文件。
  String _parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '网盘根目录' : path.substring(1, i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 30, // 接口限制：key ≤ 30 个 UTF-8 字符
          decoration: const InputDecoration(
            hintText: '搜索网盘视频（文件名关键词）',
            border: InputBorder.none,
            counterText: '',
            isDense: true,
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) {
            final key = _controller.text.trim();
            if (key.isNotEmpty) _search(key);
          },
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: '清空',
              onPressed: _controller.clear,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final key = _controller.text.trim();
    if (_error.isNotEmpty) {
      return _CenterHint(
        icon: Icons.error_outline,
        text: _error,
        action: '重试',
        onAction: () => _search(key),
      );
    }
    if (key.isEmpty) {
      return const _CenterHint(
        icon: Icons.manage_search,
        text: '输入关键词，搜索整个网盘的视频文件',
      );
    }
    if (_results.isEmpty && !_loading) {
      return const _CenterHint(icon: Icons.search_off, text: '未找到匹配的视频');
    }
    return ListView.builder(
      itemCount: _results.length + (_hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _results.length) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              '结果超过 500 条，仅展示前 500 条；可换更具体的关键词',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          );
        }
        return _buildRow(_results[i]);
      },
    );
  }

  Widget _buildRow(CloudEntry e) {
    final thumb = e.thumbUrl;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 72,
          height: 44,
          child: thumb != null
              ? Image.network(
                  thumb,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _VideoFallback(),
                )
              : const _VideoFallback(),
        ),
      ),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${e.sizeLabel} · ${_parent(e.path)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerPage(
            source: BaiduPlayableSource(
              cloudPath: e.path,
              title: e.name,
              fsId: e.fsId,
            ),
          ),
        ));
      },
    );
  }
}

/// 缩略图加载失败/缺失时的占位。
class _VideoFallback extends StatelessWidget {
  const _VideoFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade300,
      child: const Icon(Icons.videocam_outlined, color: Colors.grey),
    );
  }
}

/// 居中提示（空态/错误态）。
class _CenterHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  const _CenterHint({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey[500]),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
