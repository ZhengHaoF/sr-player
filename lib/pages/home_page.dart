import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'files_page.dart';
import 'library_page.dart';
import 'mine_page.dart';

/// 首页：权限门禁 + 三 Tab（视频 / 文件 / 我的）。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  bool _storageGranted = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置页返回后复查权限。
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final manage = await Permission.manageExternalStorage.isGranted;
    final media = await Permission.videos.isGranted;
    if (mounted) {
      setState(() {
        _storageGranted = manage;
        _checked = true;
      });
    }
    if (manage && !media) {
      // 媒体权限用于 MediaStore 视频库；被拒不影响文件浏览。
      await Permission.videos.request();
    }
  }

  Future<void> _request() async {
    await Permission.manageExternalStorage.request();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_storageGranted) return _gate();
    // key 绑定权限状态，授权后强制重建三个 Tab 以触发重新加载。
    return KeyedSubtree(
      key: ValueKey('home-$_storageGranted'),
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: const [LibraryPage(), FilesPage(), MinePage()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: '视频'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: '文件'),
            NavigationDestination(icon: Icon(Icons.person_outlined), selectedIcon: Icon(Icons.person), label: '我的'),
          ],
        ),
      ),
    );
  }

  int _tab = 0;

  Widget _gate() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_shared_outlined, size: 72, color: Colors.indigo),
              const SizedBox(height: 16),
              const Text('需要「所有文件访问」权限', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '本地播放器需要读取存储中的视频文件。\n'
                '下一步请在系统设置中允许本应用访问所有文件，然后返回。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600], height: 1.5),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _request,
                icon: const Icon(Icons.settings),
                label: const Text('去授权'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
