import 'package:flutter_test/flutter_test.dart';
import 'package:sr_player/services/netdisk/baidu_auth.dart';

/// 百度 OAuth 鉴权失败的提示映射回归测试。
///
/// 夹具是 2026-11-13 实际抓到的百度响应（占位 AppKey 请求设备码端点）：
///   HTTP 401
///   {"error":"invalid_client","error_description":"unknown client id"}
///
/// 背景：未配置真实凭证时，此前直接把 DioException 原文抛给 UI
/// （"DioException [bad response]: ... validateStatus ..."），
/// 用户无法判断是自己填错凭证还是代码有问题。此测试锁定可操作提示。
void main() {
  group('describeAuthFailure', () {
    test('401 invalid_client → 指明应用凭证问题', () {
      final msg = BaiduAuth.describeAuthFailure(401, const {
        'error': 'invalid_client',
        'error_description': 'unknown client id',
      });
      expect(msg, contains('应用凭证'));
      expect(msg, contains('HTTP 401'));
      expect(msg, contains('invalid_client'));
      expect(msg, contains('unknown client id'));
      // 指引用户去设置页改配置，而不是盯着 DioException 猜。
      expect(msg, contains('百度网盘凭证'));
    });

    test('仅凭 error 字段也能识别 invalid_client（容忍非 401 包装）', () {
      final msg = BaiduAuth.describeAuthFailure(400, const {
        'error': 'invalid_client',
      });
      expect(msg, contains('应用凭证'));
    });

    test('其他失败保留状态码与错误码，不误判为凭证问题', () {
      final msg = BaiduAuth.describeAuthFailure(500, const {
        'error': 'internal_error',
        'error_description': 'server busy',
      });
      expect(msg, isNot(contains('应用凭证')));
      expect(msg, contains('HTTP 500'));
      expect(msg, contains('internal_error'));
      expect(msg, contains('server busy'));
    });

    test('无响应体（超时/断网）也给出可读提示', () {
      final msg = BaiduAuth.describeAuthFailure(null, null);
      expect(msg, contains('无响应'));
      expect(msg, isNot(contains('应用凭证')));
    });
  });
}
