import 'baidu_secrets.dart';

/// 百度网盘开放平台应用配置。真实凭证在 gitignored 的 baidu_secrets.dart。
class BaiduConfig {
  BaiduConfig._();

  static const String appId = '24824980';
  static const String appKey = BaiduSecrets.appKey;
  static const String secretKey = BaiduSecrets.secretKey;
  static const String signKey = BaiduSecrets.signKey;

  /// 接口请求 UA（FAQ 要求包含 appName/appVersion/sysName/sysVersion）。
  static const String apiUserAgent = 'srplayer/1.1;android;14';

  /// dlink 直链必须使用的 UA（文档规范，缺失可能触发 31326 防盗链）。
  static const String downloadUserAgent = 'pan.baidu.com';
}
