import '../app_store.dart';

/// 百度网盘开放平台应用配置。
///
/// 凭证唯一来源是「我的 → 百度网盘凭证」设置页（缓存于本机
/// shared_preferences，仅本机，不上传）。未配置时登录页会给出
/// 填写引导，此时直接授权会被百度以 401 `invalid_client` 拒绝。
class BaiduConfig {
  BaiduConfig._();

  static const _kAppKey = 'baidu_app_key';
  static const _kSecretKey = 'baidu_secret_key';
  static const _kSignKey = 'baidu_sign_key';

  // ---------- 设置页填写值（未填写时为空串） ----------

  static String get userAppKey => _read(_kAppKey);
  static String get userSecretKey => _read(_kSecretKey);
  static String get userSignKey => _read(_kSignKey);

  // ---------- 生效值（= 设置页填写值；鉴权/接口层统一从这里取） ----------

  static String get appKey => userAppKey;
  static String get secretKey => userSecretKey;

  /// 是否已配置可用凭证（两项都非空）。
  static bool get credentialsConfigured =>
      appKey.isNotEmpty && secretKey.isNotEmpty;

  /// 保存设置页凭证（首尾空白裁剪；空串表示清除该项）。
  static Future<void> saveCredentials({
    required String appKey,
    required String secretKey,
    String signKey = '',
  }) async {
    await _write(_kAppKey, appKey);
    await _write(_kSecretKey, secretKey);
    await _write(_kSignKey, signKey);
  }

  /// 清除设置页凭证。
  static Future<void> clearUserCredentials() async {
    await AppStore.remove(_kAppKey);
    await AppStore.remove(_kSecretKey);
    await AppStore.remove(_kSignKey);
  }

  static String _read(String key) => (AppStore.getString(key) ?? '').trim();

  static Future<void> _write(String key, String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await AppStore.remove(key);
    } else {
      await AppStore.setString(key, v);
    }
  }

  /// 接口请求 UA（FAQ 要求包含 appName/appVersion/sysName/sysVersion）。
  static const String apiUserAgent = 'srplayer/1.1;android;14';

  /// dlink 直链必须使用的 UA（文档规范，缺失可能触发 31326 防盗链）。
  static const String downloadUserAgent = 'pan.baidu.com';
}
