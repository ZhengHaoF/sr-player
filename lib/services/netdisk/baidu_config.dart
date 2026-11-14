import '../app_store.dart';
import 'baidu_secrets.dart';

/// 百度网盘开放平台应用配置。
///
/// 凭证来源优先级：
/// 1. 设置页填写（缓存于本机 shared_preferences，仅本机，不上传）
/// 2. 编译期注入（`baidu_secrets.dart`；仓库内是 `YOUR_xxx` 占位模板）
///
/// 占位值请求百度会被以 401 `invalid_client` 拒绝，因此开箱不可用，
/// 需用户在「我的 → 百度网盘凭证」自行填写真实凭证。
class BaiduConfig {
  BaiduConfig._();

  static const String appId = '24824980';

  static const _kAppKey = 'baidu_app_key';
  static const _kSecretKey = 'baidu_secret_key';
  static const _kSignKey = 'baidu_sign_key';

  // ---------- 设置页填写值（未填写时为空串） ----------

  static String get userAppKey => _read(_kAppKey);
  static String get userSecretKey => _read(_kSecretKey);
  static String get userSignKey => _read(_kSignKey);

  // ---------- 生效值（设置页优先，否则回退编译期内置） ----------

  static String get appKey => _effective(userAppKey, BaiduSecrets.appKey);
  static String get secretKey => _effective(userSecretKey, BaiduSecrets.secretKey);
  static String get signKey => _effective(userSignKey, BaiduSecrets.signKey);

  /// 设置页是否已填好可用凭证（两项都非占位值）。
  static bool get hasUserCredentials =>
      isReal(userAppKey) && isReal(userSecretKey);

  /// 生效凭证是否可用于请求百度。
  static bool get credentialsConfigured =>
      isReal(appKey) && isReal(secretKey);

  /// 凭证来源（设置页展示用）。
  static String get sourceLabel =>
      hasUserCredentials ? '设置页填写（本机缓存）' : '编译期内置';

  /// 模板占位值（`YOUR_xxx`）不算真实凭证。
  static bool isReal(String v) => v.isNotEmpty && !v.startsWith('YOUR_');

  /// 保存设置页凭证（首尾空白裁剪；空串表示清除该项，回退内置值）。
  static Future<void> saveCredentials({
    required String appKey,
    required String secretKey,
    String signKey = '',
  }) async {
    await _write(_kAppKey, appKey);
    await _write(_kSecretKey, secretKey);
    await _write(_kSignKey, signKey);
  }

  /// 清除设置页凭证，回退到编译期内置值。
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

  static String _effective(String user, String fallback) =>
      user.isEmpty ? fallback : user;

  /// 接口请求 UA（FAQ 要求包含 appName/appVersion/sysName/sysVersion）。
  static const String apiUserAgent = 'srplayer/1.1;android;14';

  /// dlink 直链必须使用的 UA（文档规范，缺失可能触发 31326 防盗链）。
  static const String downloadUserAgent = 'pan.baidu.com';
}
