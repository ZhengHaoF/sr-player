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

  /// 是否已填入真实应用凭证（设置页填写或编译期注入，且非模板占位值）。
  /// 占位值请求百度会被以 401 invalid_client 拒绝，提前拦截以给出可操作提示。
  static bool get credentialsConfigured => BaiduConfig.credentialsConfigured;

  /// 把百度鉴权失败（HTTP 状态 + 响应体）翻译成可操作的中文提示。
  /// 纯函数，便于单测；401 / `invalid_client` 是未配置或凭证被拒的真实返回。
  static String describeAuthFailure(int? status, Object? body) {
    final err = body is Map ? (body['error'] as String?) : null;
    final desc = body is Map ? (body['error_description'] as String?) : null;
    final detail = [?err, ?desc].join('：');
    if (status == 401 || err == 'invalid_client') {
      return '应用凭证被百度拒绝（HTTP ${status ?? 401}'
          '${detail.isEmpty ? '' : ' / $detail'}）。'
          '请在「我的 → 百度网盘凭证」重新填写开放平台应用凭证页的 '
          'AppKey/SecretKey，并确认包名与签名证书已在开放平台登记。';
    }
    return '网络请求失败（HTTP ${status ?? '无响应'}'
        '${detail.isEmpty ? '' : ' / $detail'}）';
  }

  static Never _throwFriendly(DioException e) => throw BaiduAuthException(
        describeAuthFailure(e.response?.statusCode, e.response?.data),
      );

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
    if (!credentialsConfigured) {
      throw BaiduAuthException(
        '未配置百度应用凭证：请到「我的 → 百度网盘凭证」填写开放平台'
        '（pan.baidu.com/union）应用凭证页的 AppKey / SecretKey。',
      );
    }
    final Map<String, dynamic>? data;
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://openapi.baidu.com/oauth/2.0/device/code',
        queryParameters: {
          'response_type': 'device_code',
          'client_id': BaiduConfig.appKey,
          'scope': 'basic,netdisk',
        },
      );
      data = r.data;
    } on DioException catch (e) {
      _throwFriendly(e);
    }
    if (data == null || (data['device_code'] as String?)?.isEmpty != false) {
      throw BaiduAuthException('获取设备码失败：$data');
    }
    return data;
  }

  /// 用指定 AppKey 探测凭证是否被百度接受（只索取设备码，不完成授权）。
  /// 返回 null 表示有效；否则返回可读的失败原因（不抛异常，供设置页直接展示）。
  static Future<String?> probeAppKey(String appKey) async {
    final k = appKey.trim();
    if (k.isEmpty) return '请先填写 AppKey';
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://openapi.baidu.com/oauth/2.0/device/code',
        queryParameters: {
          'response_type': 'device_code',
          'client_id': k,
          'scope': 'basic,netdisk',
        },
      );
      final ok = (r.data?['device_code'] as String?)?.isNotEmpty == true;
      return ok ? null : '意外的响应：${r.data}';
    } on DioException catch (e) {
      return describeAuthFailure(e.response?.statusCode, e.response?.data);
    }
  }

  /// 第二步轮询：用 device_code 换 token。
  /// 返回 'pending'（继续轮询）/ 'ok'（成功）/ 'expired'（设备码过期）/ 'slowdown'。
  static Future<String> pollDeviceToken(String deviceCode) async {
    final Map<String, dynamic>? payload;
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://openapi.baidu.com/oauth/2.0/token',
        queryParameters: {
          'grant_type': 'device_token',
          'client_id': BaiduConfig.appKey,
          'client_secret': BaiduConfig.secretKey,
          'code': deviceCode,
        },
      );
      payload = r.data;
    } on DioException catch (e) {
      _throwFriendly(e);
    }
    final data = payload ?? const {};
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
