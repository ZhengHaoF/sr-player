import 'package:flutter/material.dart';

import '../services/netdisk/baidu_auth.dart';
import '../services/netdisk/baidu_config.dart';

/// 百度网盘凭证设置页：填写 AppKey / SecretKey → 缓存本机 → 可选即时验证。
///
/// 凭证只写入本机 shared_preferences，不上传、不入库。
/// 未填写时回退编译期内置值（仓库内为 `YOUR_xxx` 占位模板，不可用）。
class NetdiskCredentialsPage extends StatefulWidget {
  const NetdiskCredentialsPage({super.key});

  @override
  State<NetdiskCredentialsPage> createState() => _NetdiskCredentialsPageState();
}

class _NetdiskCredentialsPageState extends State<NetdiskCredentialsPage> {
  final _appKey = TextEditingController(text: BaiduConfig.userAppKey);
  final _secretKey = TextEditingController(text: BaiduConfig.userSecretKey);
  final _signKey = TextEditingController(text: BaiduConfig.userSignKey);

  bool _obscure = true;
  bool _busy = false;
  bool _ok = false;
  String _result = '';

  @override
  void dispose() {
    _appKey.dispose();
    _secretKey.dispose();
    _signKey.dispose();
    super.dispose();
  }

  Future<void> _save({required bool verify}) async {
    setState(() {
      _busy = true;
      _result = '';
    });
    await BaiduConfig.saveCredentials(
      appKey: _appKey.text,
      secretKey: _secretKey.text,
      signKey: _signKey.text,
    );
    var ok = true;
    var msg = '已保存到本机';
    if (verify) {
      final err = await BaiduAuth.probeAppKey(BaiduConfig.appKey);
      ok = err == null;
      msg = ok
          ? '已保存，凭证有效（百度已接受该 AppKey）'
          : '已保存，但验证未通过：$err';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = ok;
      _result = msg;
    });
  }

  Future<void> _clear() async {
    await BaiduConfig.clearUserCredentials();
    if (!mounted) return;
    setState(() {
      _appKey.clear();
      _secretKey.clear();
      _signKey.clear();
      _ok = false;
      _result = '已清除本机凭证，回退编译期内置值';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = BaiduConfig.credentialsConfigured;
    return Scaffold(
      appBar: AppBar(
        title: const Text('百度网盘凭证'),
        actions: [
          IconButton(
            tooltip: '清除本机凭证',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : _clear,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(ready ? Icons.verified_user_outlined : Icons.warning_amber_outlined,
                  color: ready ? Colors.green : Colors.orange),
              title: Text(ready ? '凭证已就绪' : '凭证未配置'),
              subtitle: Text('来源：${BaiduConfig.sourceLabel}'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _appKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'AppKey',
              helperText: '开放平台「应用凭证」页的 API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _secretKey,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'SecretKey',
              helperText: '开放平台「应用凭证」页的 Secret Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示' : '隐藏',
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('SignKey（可选）', style: TextStyle(fontSize: 14)),
            subtitle: const Text('当前功能未使用，留存备用', style: TextStyle(fontSize: 12)),
            children: [
              TextField(
                controller: _signKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'SignKey',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : () => _save(verify: true),
                  child: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('保存并验证'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => _save(verify: false),
                child: const Text('仅保存'),
              ),
            ],
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_result,
                style: TextStyle(
                    fontSize: 13, color: _ok ? Colors.green[700] : Colors.red[700])),
          ],
          const SizedBox(height: 24),
          Text(
            '· 凭证保存在本机（shared_preferences），不会上传到任何服务器。\n'
            '· 获取方式：pan.baidu.com/union → 应用管理 → 应用凭证。\n'
            '· 百度按「AppKey + 包名 + 签名证书」校验，若提示凭证被拒，'
            '请确认开放平台登记的包名为 dev.srplayer.sr_player，'
            '且签名证书与本机 APK 一致。\n'
            '· 填写后立即生效，无需重启应用。',
            style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.6),
          ),
        ],
      ),
    );
  }
}
