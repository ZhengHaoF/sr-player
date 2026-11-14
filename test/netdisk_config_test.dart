import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sr_player/services/app_store.dart';
import 'package:sr_player/services/netdisk/baidu_config.dart';
import 'package:sr_player/services/netdisk/baidu_secrets.dart';

/// 凭证解析优先级回归测试：设置页填写 → 回退编译期内置。
///
/// 断言不依赖内置值是真凭证还是 `YOUR_xxx` 占位模板，
/// 因此本地开发（占位）与填过真实凭证的环境下都成立。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStore.init();
  });

  test('未填写时回退编译期内置值，且不认为设置了用户凭证', () {
    expect(BaiduConfig.userAppKey, isEmpty);
    expect(BaiduConfig.userSecretKey, isEmpty);
    expect(BaiduConfig.hasUserCredentials, isFalse);
    expect(BaiduConfig.appKey, BaiduSecrets.appKey);
    expect(BaiduConfig.secretKey, BaiduSecrets.secretKey);
  });

  test('设置页保存后覆盖内置值（首尾空白裁剪）', () async {
    await BaiduConfig.saveCredentials(
      appKey: '  my_app_key  ',
      secretKey: ' my_secret ',
    );
    expect(BaiduConfig.userAppKey, 'my_app_key');
    expect(BaiduConfig.appKey, 'my_app_key');
    expect(BaiduConfig.secretKey, 'my_secret');
    expect(BaiduConfig.hasUserCredentials, isTrue);
    expect(BaiduConfig.credentialsConfigured, isTrue);
    expect(BaiduConfig.sourceLabel, contains('设置页'));
  });

  test('清除后回退内置值', () async {
    await BaiduConfig.saveCredentials(appKey: 'k', secretKey: 's');
    expect(BaiduConfig.appKey, 'k');

    await BaiduConfig.clearUserCredentials();
    expect(BaiduConfig.userAppKey, isEmpty);
    expect(BaiduConfig.appKey, BaiduSecrets.appKey);
    expect(BaiduConfig.hasUserCredentials, isFalse);
  });

  test('只填一半不算配置完成（SecretKey 缺失）', () async {
    await BaiduConfig.saveCredentials(appKey: 'only_key', secretKey: '   ');
    expect(BaiduConfig.appKey, 'only_key');
    expect(BaiduConfig.userSecretKey, isEmpty);
    expect(BaiduConfig.hasUserCredentials, isFalse);
    expect(BaiduConfig.credentialsConfigured, isFalse);
  });

  test('占位模板值不被当作真实凭证', () {
    expect(BaiduConfig.isReal('YOUR_APP_KEY'), isFalse);
    expect(BaiduConfig.isReal(''), isFalse);
    expect(BaiduConfig.isReal('abc123'), isTrue);
  });
}
