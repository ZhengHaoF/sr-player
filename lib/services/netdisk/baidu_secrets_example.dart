/// 百度网盘开放平台真实凭证模板。
///
/// 使用：复制本文件为同目录下的 `baidu_secrets.dart`（已 gitignore，不会入库），
/// 填入你在 pan.baidu.com/union 创建应用拿到的真实值。
class BaiduSecrets {
  BaiduSecrets._();

  /// 应用 AppKey（开放平台「应用凭证」页）。
  static const String appKey = 'YOUR_APP_KEY';

  /// SecretKey（打包进 APK 是开放平台模式的标准做法，
  /// 安全性由 AppKey 绑定包名 + 签名证书兜底）。
  static const String secretKey = 'YOUR_SECRET_KEY';

  /// SignKey（接口签名用，本应用当前未直接使用，留存备用）。
  static const String signKey = 'YOUR_SIGN_KEY';
}
