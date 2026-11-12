import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// 轻量本地持久化：SR 档位、收藏文件夹、断点续播、播放记录、偏好。
/// v1 规模（收藏几十、记录几百）用 JSON 存 shared_preferences 足够。
class AppStore {
  AppStore._();
  static late SharedPreferences _p;

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
  }

  // ---------- SR 档位 ----------

  static SrMode get srMode {
    final v = _p.getString('sr_mode');
    return SrMode.values.firstWhere((e) => e.name == v, orElse: () => SrMode.off);
  }

  static Future<void> setSrMode(SrMode m) => _p.setString('sr_mode', m.name);

  // ---------- 偏好 ----------

  static bool get showHidden => _p.getBool('show_hidden') ?? false;
  static Future<void> setShowHidden(bool v) => _p.setBool('show_hidden', v);

  // ---------- 收藏文件夹 ----------

  static List<String> get favorites => _p.getStringList('favorites') ?? [];

  static bool isFavorite(String path) => favorites.contains(path);

  static Future<void> toggleFavorite(String path) async {
    final list = favorites;
    if (!list.remove(path)) list.add(path);
    await _p.setStringList('favorites', list);
  }

  // ---------- 断点续播 / 播放记录 ----------

  static const int _historyCap = 100;

  static Map<String, dynamic>? getPosition(String path) {
    final raw = _p.getString('position:$path');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> removePosition(String path) => _p.remove('position:$path');

  static Future<void> recordPlayback({
    required String path,
    required String name,
    required int posMs,
    required int durMs,
  }) async {
    await _p.setString(
      'position:$path',
      jsonEncode({'pos': posMs, 'dur': durMs, 'updated': DateTime.now().millisecondsSinceEpoch}),
    );
    // 更新历史列表（最新在前，去重，截断）。
    final raw = _p.getString('history');
    List list = [];
    try {
      list = raw == null ? [] : (jsonDecode(raw) as List);
    } catch (_) {}
    list.removeWhere((e) => e is Map && e['path'] == path);
    list.insert(0, {
      'path': path,
      'name': name,
      'pos': posMs,
      'dur': durMs,
      'updated': DateTime.now().millisecondsSinceEpoch,
    });
    if (list.length > _historyCap) list = list.sublist(0, _historyCap);
    await _p.setString('history', jsonEncode(list));
  }

  static List<Map<String, dynamic>> history() {
    final raw = _p.getString('history');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> removeHistory(String path) async {
    final list = history()..removeWhere((e) => e['path'] == path);
    await _p.setString('history', jsonEncode(list));
    await removePosition(path);
  }

  static Future<void> clearHistory() async {
    await _p.remove('history');
    // 逐条清除续播点。
    for (final key in _p.getKeys().where((k) => k.startsWith('position:')).toList()) {
      await _p.remove(key);
    }
  }

  // ---------- 通用键值（百度网盘 token / 偏好等使用） ----------

  static String? getString(String key) => _p.getString(key);
  static Future<void> setString(String key, String value) =>
      _p.setString(key, value);
  static int? getInt(String key) => _p.getInt(key);
  static Future<void> setInt(String key, int value) => _p.setInt(key, value);
  static Future<void> remove(String key) => _p.remove(key);
}
