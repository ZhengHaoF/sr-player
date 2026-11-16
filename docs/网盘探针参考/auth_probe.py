# -*- coding: utf-8 -*-
"""设备码授权 + 探针一体化脚本（托管长任务用）。

流程：
  1. 申请设备码，打印 USER_CODE / QRCODE
  2. 轮询 token；设备码过期/吊销时自动换新码（打印 CODE_EXPIRED_RENEWING + 新 USER_CODE）
  3. 授权成功：token 写入系统临时目录（不回显），自动运行同目录 probe.py 并透传输出
  4. 总时限 15 分钟，超时退出码 2

凭证从环境变量读取（不在文件里硬编码）：
    BD_AUTH_KEY=<AppKey> BD_AUTH_SECRET=<SecretKey> python -I auth_probe.py
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

APP_KEY = os.environ.get("BD_AUTH_KEY", "")
APP_SECRET = os.environ.get("BD_AUTH_SECRET", "")
TD = tempfile.gettempdir()
DEADLINE = time.time() + 15 * 60
UA = "srplayer-auth/0.1;android;14"


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return json.loads(body)
        except Exception:
            return {"error": "http_%d" % e.code, "raw": body[:200]}


def mint_code():
    """申请设备码并打印，返回 device_code。"""
    q = urllib.parse.urlencode({"response_type": "device_code",
                                "client_id": APP_KEY, "scope": "basic,netdisk"})
    d = http_json("https://openapi.baidu.com/oauth/2.0/device/code?" + q)
    if "device_code" not in d:
        print("MINT_FAIL:", json.dumps(d, ensure_ascii=False)[:200], flush=True)
        sys.exit(1)
    open(os.path.join(TD, "bd_device_code"), "w").write(d["device_code"])
    print("USER_CODE: %s" % d.get("user_code"), flush=True)
    print("QRCODE: %s" % d.get("qrcode_url"), flush=True)
    print("VALID_SECONDS: %s" % d.get("expires_in"), flush=True)
    return d["device_code"]


def poll_once(dc):
    q = urllib.parse.urlencode({"grant_type": "device_token", "client_id": APP_KEY,
                                "client_secret": APP_SECRET, "code": dc})
    return http_json("https://openapi.baidu.com/oauth/2.0/token?" + q)


def main():
    if not APP_KEY or not APP_SECRET:
        print("缺少 BD_AUTH_KEY / BD_AUTH_SECRET 环境变量", flush=True)
        sys.exit(1)
    dc = mint_code()
    while time.time() < DEADLINE:
        d = poll_once(dc)
        if "access_token" in d:
            open(os.path.join(TD, "bd_token"), "w").write(d["access_token"])
            open(os.path.join(TD, "bd_refresh"), "w").write(d.get("refresh_token", ""))
            print("AUTH_OK | scope: %s | expires_in: %s"
                  % (d.get("scope"), d.get("expires_in")), flush=True)
            here = os.path.dirname(os.path.abspath(__file__))
            env = dict(os.environ, BD_TOKEN=d["access_token"], PYTHONUTF8="1")
            r = subprocess.run([sys.executable, "-I", os.path.join(here, "probe.py")],
                               env=env, cwd=here)
            print("PROBE_EXIT: %d" % r.returncode, flush=True)
            return
        err = d.get("error", "")
        if err == "authorization_pending":
            time.sleep(6)
            continue
        # 过期/吊销等：自动换新码继续等
        print("CODE_EXPIRED_RENEWING (%s)" % err, flush=True)
        dc = mint_code()
    print("TIMEOUT_15MIN", flush=True)
    sys.exit(2)


main()
