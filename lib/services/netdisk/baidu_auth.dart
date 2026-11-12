import 'package:dio/dio.dart';

import 'baidu_config.dart';
import '../app_store.dart';

/// 百度网盘设备码 OAuth（手册 A.1）：取码 → 用户授权 → 轮询换 token。
/// token 30 天有效，refresh_token 续期；持久化走 AppStore（shared_preferences）。
class BaiduAuth {
  BaiduAuth._();

  static const _kAccess = 'baidu_access_token';
  static const _kRefresh = 'baidu_refresh_token';
  static const _kExpiresAt = 'baidu_expires_at'; // 毫秒时间戳

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  static String? get accessToken => AppStore.getString(_kAccess);
  static String? get refreshToken => AppStore.getString(_kRefresh);

  /// 本地记录的过期时间（毫秒）；未知时视为已过期以触发刷新。
  static int? get _expiresAt => AppStore.getInt(_kExpiresAt);

  static bool get hasToken => (accessToken ?? '').isNotEmpty;

  /// token 是否可用（留 2 分钟提前量）。没有 token 时返回 false。
  static Future<bool> ensureValid() async {
    if (!hasToken) return false;
    final exp = _expiresAt ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (exp - now > 2 * 60 * 1000) return true;
    return await refresh();
  }

  /// 第一步：申请设备码。返回 demo 字段（device_code/user_code/verification_url 等）。
  static Future<Map<String, dynamic>> requestDeviceCode() async {
    final r = await _dio.get<Map<String, dynamic>>(
      'https://openapi.baidu.com/oauth/2.0/device/code',
      queryParameters: {
        'response_type': 'device_code',
        'client_id': BaiduConfig.appKey,
        'scope': 'basic,netdisk',
      },
    );
    final data = r.data;
    if (data == null || (data['device_code'] as String?)?.isEmpty != false) {
      throw BaiduAuthException('获取设备码失败：${r.data}');
    }
    return data;
  }

  /// 第二步轮询：用 device_code 换 token。
  /// 返回 'pending'（继续轮询）/ 'ok'（成功）/ 'expired'（设备码过期）/ 'slowdown'。
  static Future<String> pollDeviceToken(String deviceCode) async {
    final r = await _dio.get<Map<String, dynamic>>(
      'https://openapi.baidu.com/oauth/2.0/token',
      queryParameters: {
        'grant_type': 'device_token',
        'client_id': BaiduConfig.appKey,
        'client_secret': BaiduConfig.secretKey,
        'code': deviceCode,
      },
    );
    final data = r.data ?? const {};
    final access = data['access_token'] as String?;
    if (access != null && access.isNotEmpty) {
      await _store(data);
      return 'ok';
    }
    final err = (data['error'] as String?) ?? '';
    if (err == 'authorization_pending') return 'pending';
    if (err == 'slow_down') return 'slowdown';
    if (err.contains('expired') || err == 'invalid_grant') return 'expired';
    return 'expired';
  }

  /// 刷新 token；失败清除本地凭据（视为未登录）。返回是否成功。
  static Future<bool> refresh() async {
    final rt = refreshToken;
    if (rt == null || rt.isEmpty) {
      await logout();
      return false;
    }
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://openapi.baidu.com/oauth/2.0/token',
        queryParameters: {
          'grant_type': 'refresh_token',
          'refresh_token': rt,
          'client_id': BaiduConfig.appKey,
          'client_secret': BaiduConfig.secretKey,
        },
      );
      final data = r.data ?? const {};
      final access = data['access_token'] as String?;
      if (access != null && access.isNotEmpty) {
        await _store(data);
        return true;
      }
    } on DioException catch (e) {
      _log('refresh 失败: $e');
    }
    await logout();
    return false;
  }

  static Future<void> logout() async {
    await AppStore.remove(_kAccess);
    await AppStore.remove(_kRefresh);
    await AppStore.remove(_kExpiresAt);
  }

  static Future<void> _store(Map<String, dynamic> data) async {
    await AppStore.setString(_kAccess, data['access_token'] as String);
    final rt = data['refresh_token'] as String?;
    if (rt != null && rt.isNotEmpty) await AppStore.setString(_kRefresh, rt);
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 2592000;
    await AppStore.setInt(
      _kExpiresAt,
      DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    );
  }

  static void _log(String msg) {
    // ignore: avoid_print
    print('[baidu-auth] $msg');
  }
}

class BaiduAuthException implements Exception {
  final String message;
  BaiduAuthException(this.message);
  @override
  String toString() => message;
}
