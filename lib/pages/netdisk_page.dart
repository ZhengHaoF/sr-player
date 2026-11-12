import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/netdisk/baidu_api.dart';
import '../services/netdisk/baidu_auth.dart';
import '../services/netdisk/play_source.dart';
import '../state.dart';
import 'player_page.dart';

/// 网盘 Tab：百度网盘登录 + 云端目录浏览 + 在线播放。
/// 未登录显示设备码授权引导；已登录为目录浏览器（分页、面包屑、封面）。
class NetdiskPage extends ConsumerStatefulWidget {
  const NetdiskPage({super.key});

  @override
  ConsumerState<NetdiskPage> createState() => _NetdiskPageState();
}

class _NetdiskPageState extends ConsumerState<NetdiskPage> {
  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(cloudLoggedInProvider);
    if (!loggedIn) return const _LoginView();
    return const _NetdiskBrowser();
  }
}

// ---------------------------------------------------------------------------
// 登录视图
// ---------------------------------------------------------------------------

class _LoginView extends StatelessWidget {
  const _LoginView();

  Future<void> _startLogin(BuildContext context) async {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const _DeviceCodePage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_outlined, size: 72, color: Colors.indigo),
              const SizedBox(height: 16),
              const Text('登录百度网盘',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '使用设备码授权：应用生成一个设备码，\n'
                '你在任意浏览器打开百度授权页输入即可。\n'
                '授权一次，30 天内免登录（自动续期）。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600], height: 1.5),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => _startLogin(context),
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('开始授权'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设备码授权页：取码 → 展示 user_code → 轮询 → 登录成功。
class _DeviceCodePage extends StatefulWidget {
  const _DeviceCodePage();

  @override
  State<_DeviceCodePage> createState() => _DeviceCodePageState();
}

class _DeviceCodePageState extends State<_DeviceCodePage> {
  Map<String, dynamic>? _device;
  String _error = '';
  String _status = ''; // 授权中 / 已授权 / 已过期 / 请求失败
  bool _busy = true;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final device = await BaiduAuth.requestDeviceCode();
      if (_disposed) return;
      setState(() {
        _device = device;
        _busy = false;
        _status = '等待授权';
      });
      _poll(device);
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _poll(Map<String, dynamic> device) async {
    final interval =
        ((device['interval'] as num?)?.toInt() ?? 5) + 2; // +2s 容错
    while (!_disposed) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (_disposed) return;
      try {
        final r = await BaiduAuth.pollDeviceToken(
            device['device_code'] as String);
        if (_disposed) return;
        if (r == 'ok') {
          setState(() => _status = '授权成功');
          if (mounted) {
            Navigator.of(context).pop(true);
          }
          return;
        }
        if (r == 'expired') {
          setState(() => _status = '设备码已过期，请重新获取');
          return;
        }
        // pending / slowdown → 继续轮询。
      } catch (e) {
        debugPrint('[netdisk] 轮询失败: $e'); // 网络抖动，继续下一轮
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final userCode = (device?['user_code'] as String?) ?? '';
    final url = (device?['verification_url'] as String?) ??
        'https://openapi.baidu.com/device';
    return Scaffold(
      appBar: AppBar(title: const Text('百度网盘授权')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_error.isNotEmpty) ...[
                  Text('请求失败：$_error', style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: _begin, child: const Text('重试')),
                ] else if (device != null) ...[
                  const Text('第一步 · 在任意浏览器打开百度授权页',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      launchUrl(Uri.parse(url),
                          mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开授权页 openapi.baidu.com/device'),
                  ),
                  const SizedBox(height: 24),
                  const Text('第二步 · 输入设备码',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  // user_code 短且需手动输入：大号显示 + 可复制。
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(children: [
                        SelectableText(
                          userCode,
                          style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 4),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () async {
                            // 复制到剪贴板。
                            await Clipboard.setData(
                                ClipboardData(text: userCode));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已复制')));
                            }
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制设备码'),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    if (_status == '等待授权')
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    if (_status == '等待授权') const SizedBox(width: 10),
                    Expanded(child: Text(_status)),
                    if (_status.contains('过期'))
                      TextButton(onPressed: _begin, child: const Text('重新获取')),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    '保持本页打开：授权完成后应用会自动进入网盘。\n'
                    '授权一次，30 天内免登录。',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey[600], height: 1.5),
                  ),
                ],
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// 云盘浏览器
// ---------------------------------------------------------------------------

class _NetdiskBrowser extends ConsumerStatefulWidget {
  const _NetdiskBrowser();

  @override
  ConsumerState<_NetdiskBrowser> createState() => _NetdiskBrowserState();
}

class _NetdiskBrowserState extends ConsumerState<_NetdiskBrowser>
    with AutomaticKeepAliveClientMixin {
  List<CloudEntry> _entries = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String _error = '';
  String _order = 'name'; // name / time / size
  bool _desc = false;
  (int, int)? _quota; // (used, total)
  final Map<int, String> _thumbs = {}; // fsId → 缩略图 URL
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  String get _path => ref.read(cloudPathProvider);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    ref.listenManual(cloudPathProvider, (prev, next) {
      if (prev != next) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore ||
        _loadingMore ||
        _loading ||
        !_scroll.position.extentAfter.isFinite ||
        _scroll.position.extentAfter > 600) {
      return;
    }
    _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
      _hasMore = false;
    });
    final current = _path;
    try {
      final (entries, hasMore) = await BaiduApi.list(current,
          limit: 100, order: _order, desc: _desc);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _hasMore = hasMore;
        _loading = false;
      });
      _loadThumbs(entries);
      _loadQuota();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final (entries, hasMore) = await BaiduApi.list(_path,
          start: _entries.length, limit: 100, order: _order, desc: _desc);
      if (!mounted) return;
      setState(() {
        _entries.addAll(entries);
        _hasMore = hasMore;
        _loadingMore = false;
      });
      _loadThumbs(entries);
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 批量取视频缩略图。实测 thumbs 仅在 dlink=1 时返回（手册 A.2），
  /// 一批最多 100 个 fsid。
  Future<void> _loadThumbs(List<CloudEntry> entries) async {
    final missing = entries
        .where((e) => e.isVideo && !_thumbs.containsKey(e.fsId))
        .map((e) => e.fsId)
        .take(100)
        .toList();
    if (missing.isEmpty) return;
    try {
      final metas = await BaiduApi.filemetas(missing, dlink: true, thumb: true);
      if (!mounted) return;
      setState(() {
        for (final id in missing) {
          final t = metas[id]?['thumbs'];
          if (t is! Map) continue;
          // url3 为大图，列表封面用它；缺失时退 icon。
          final url =
              (t['url3'] ?? t['url2'] ?? t['url1'] ?? t['icon']) as String?;
          if (url != null && url.isNotEmpty) _thumbs[id] = url;
        }
      });
    } catch (e) {
      debugPrint('[netdisk] 缩略图获取失败: $e'); // 非关键路径，静默
    }
  }

  Future<void> _loadQuota() async {
    if (_quota != null) return;
    try {
      final q = await BaiduApi.quota();
      if (!mounted) return;
      setState(() => _quota = q);
    } catch (_) {// 非关键路径
    }
  }

  void _enter(String path) {
    ref.read(cloudPathProvider.notifier).set(path);
  }

  Future<void> _pickSort() async {
    final sel = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          MediaQuery.of(context).size.width - 8, 8, 8, 0),
      items: const [
        PopupMenuItem(value: 'name', child: Text('按名称')),
        PopupMenuItem(value: 'time', child: Text('按时间（新→旧）')),
        PopupMenuItem(value: 'size', child: Text('按大小（大→小）')),
      ],
    );
    if (sel == null || sel == _order) return;
    setState(() {
      _order = sel;
      _desc = sel != 'name';
    });
    _load();
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('将清除本机的网盘授权凭据，下次观看需重新授权。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(cloudLoggedInProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final path = ref.watch(cloudPathProvider);
    final dirName = path == '/' ? '网盘根目录' : path.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text(dirName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '排序',
            onPressed: _pickSort,
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 面包屑。
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: _buildCrumbs(path),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  List<Widget> _buildCrumbs(String path) {
    final crumbs = <(String, String)>[('网盘根', '/')];
    var acc = '';
    for (final seg in path.split('/')) {
      if (seg.isEmpty) continue;
      acc = '$acc/$seg';
      crumbs.add((seg, acc));
    }
    return [
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
                  color: fullPath == path
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey[600],
                  fontWeight: fullPath == path ? FontWeight.bold : null,
                ),
              ),
            ),
          ),
          if (fullPath != path)
            Icon(Icons.chevron_right, size: 16, color: Colors.grey[500]),
        ]),
    ];
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 56, color: Colors.grey[500]),
              const SizedBox(height: 8),
              Text(_error, textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600])),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _entries.isEmpty
          ? ListView(children: [
              _buildQuotaHeader(),
              const SizedBox(height: 80),
              const Center(child: Text('空目录', style: TextStyle(color: Colors.grey))),
            ])
          : ListView.builder(
              controller: _scroll,
              itemCount: _entries.length + 1 + (_hasMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (i == 0) return _buildQuotaHeader();
                final idx = i - 1;
                if (idx >= _entries.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  );
                }
                return _buildRow(_entries[idx]);
              },
            ),
    );
  }

  /// 容量信息头（登录账号 + 已用/总量）。
  Widget _buildQuotaHeader() {
    final q = _quota;
    return ListTile(
      leading: Icon(Icons.cloud_outlined, color: Colors.indigo.shade300, size: 32),
      title: Text(
        q == null
            ? '百度网盘'
            : '已用 ${_fmtSize(q.$1)} / 共 ${_fmtSize(q.$2)}（${(q.$1 / q.$2 * 100).toStringAsFixed(1)}%）',
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: q == null
          ? const Text('容量信息加载中…', style: TextStyle(fontSize: 11))
          : LinearProgressIndicator(
              value: q.$2 > 0 ? q.$1 / q.$2 : 0,
              minHeight: 3,
              backgroundColor: Colors.grey.shade200,
            ),
      dense: true,
    );
  }

  String _fmtSize(int bytes) {
    final gb = bytes / 1073741824;
    if (gb >= 1024) return '${(gb / 1024).toStringAsFixed(2)} TB';
    return '${gb.toStringAsFixed(0)} GB';
  }

  Widget _buildRow(CloudEntry e) {
    if (e.isDir) {
      return ListTile(
        leading: Icon(Icons.folder, color: Colors.amber.shade600, size: 32),
        title: Text(e.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _enter(e.path),
        trailing: const Icon(Icons.chevron_right, size: 20),
      );
    }
    if (!e.isVideo) {
      return ListTile(
        leading: Icon(Icons.insert_drive_file_outlined,
            color: Colors.grey[500], size: 28),
        title: Text(e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        subtitle: e.sizeLabel.isEmpty
            ? null
            : Text(e.sizeLabel, style: const TextStyle(fontSize: 11)),
        dense: true,
      );
    }
    // 视频条目：封面 + 名称 + 大小，点击在线播放。
    final thumbUrl = _thumbs[e.fsId];
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 72,
          height: 44,
          child: thumbUrl != null
              ? Image.network(
                  thumbUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _videoPlaceholder(),
                  // 缩略图 URL 带 8h 签名，不缓存到磁盘。
                )
              : _videoPlaceholder(),
        ),
      ),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${e.sizeLabel} · ${_fmtDate(e.modifiedSec)}',
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () {
        Navigator.of(context)
            .push(MaterialPageRoute(
          builder: (_) => PlayerPage(
            source: BaiduPlayableSource(
              cloudPath: e.path,
              title: e.name,
              fsId: e.fsId,
            ),
          ),
        ))
            .then((_) => _load());
      },
    );
  }

  Widget _videoPlaceholder() => Container(
        color: Colors.grey.shade300,
        child: const Icon(Icons.videocam_outlined, color: Colors.grey),
      );

  String _fmtDate(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}/${d.month}/${d.day}';
  }
}
