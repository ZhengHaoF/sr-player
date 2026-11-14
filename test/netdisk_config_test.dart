import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sr_player/services/app_store.dart';
import 'package:sr_player/services/netdisk/baidu_config.dart';

/// 凭证配置回归测试：设置页是唯一凭证来源，未配置即网盘不可用。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStore.init();
  });

  test('未配置时各项为空且 credentialsConfigured 为 false', () {
    expect(BaiduConfig.userAppKey, isEmpty);
    expect(BaiduConfig.userSecretKey, isEmpty);
    expect(BaiduConfig.appKey, isEmpty);
    expect(BaiduConfig.secretKey, isEmpty);
    expect(BaiduConfig.credentialsConfigured, isFalse);
  });

  test('设置页保存后生效（首尾空白裁剪）', () async {
    await BaiduConfig.saveCredentials(
      appKey: '  my_app_key  ',
      secretKey: ' my_secret ',
    );
    expect(BaiduConfig.userAppKey, 'my_app_key');
    expect(BaiduConfig.appKey, 'my_app_key');
    expect(BaiduConfig.secretKey, 'my_secret');
    expect(BaiduConfig.credentialsConfigured, isTrue);
  });

  test('清除后回到未配置状态', () async {
    await BaiduConfig.saveCredentials(appKey: 'k', secretKey: 's');
    expect(BaiduConfig.credentialsConfigured, isTrue);

    await BaiduConfig.clearUserCredentials();
    expect(BaiduConfig.userAppKey, isEmpty);
    expect(BaiduConfig.appKey, isEmpty);
    expect(BaiduConfig.credentialsConfigured, isFalse);
  });

  test('只填一半不算配置完成（SecretKey 缺失）', () async {
    await BaiduConfig.saveCredentials(appKey: 'only_key', secretKey: '   ');
    expect(BaiduConfig.appKey, 'only_key');
    expect(BaiduConfig.userSecretKey, isEmpty);
    expect(BaiduConfig.credentialsConfigured, isFalse);
  });
}
