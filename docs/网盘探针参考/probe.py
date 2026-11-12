# -*- coding: utf-8 -*-
"""百度网盘 xpan REST API 探针（只读，stdout 输出）。

配套文档：docs/网盘在线播放评估.md 附录 A（接口调用手册）。

用法：
    export BD_TOKEN=<access_token>   # 设备码 OAuth 获取，30 天有效
    python -I probe.py

无硬编码密钥；全只读调用（list/filemetas/streaming/dlink Range），不写盘、不删除。
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

TOKEN = os.environ.get("BD_TOKEN", "")
UA = "srplayer-probe/0.1;android;14"  # appName/appVersion;sysName;sysVersion 按文档规范
PAN = "https://pan.baidu.com/rest/2.0/xpan"


def get(url, headers=None, timeout=30):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def api(subpath, method, **params):
    """GET pan.baidu.com/rest/2.0/xpan/<subpath>?method=...&access_token=..."""
    p = {"method": method, "access_token": TOKEN}
    p.update({k: v for k, v in params.items() if v is not None})
    url = PAN + "/" + subpath + "?" + urllib.parse.urlencode(p)
    status, headers, body = get(url)
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        # 端点拼错时百度返回 HTML 404 页，不是 JSON
        data = {"_non_json": body[:200].decode("utf-8", "replace")}
    return status, headers, data


def raw(base, params):
    url = base + "?" + urllib.parse.urlencode(params)
    status, headers, body = get(url)
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        data = {"_non_json": body[:200].decode("utf-8", "replace")}
    return status, data


def banner(t):
    print("\n" + "=" * 12 + " " + t + " " + "=" * 12)


def errno_of(d):
    return d.get("errno") if isinstance(d, dict) else None


def main():
    if not TOKEN:
        print("缺少 BD_TOKEN 环境变量（设备码 OAuth 获取，见手册 A.1）")
        sys.exit(1)
    results = []

    # 1) uinfo
    banner("uinfo（用户信息）")
    st, _, d = api("nas", "uinfo")
    print("http", st, "| 网盘名:", d.get("netdisk_name"))
    results.append(("uinfo", errno_of(d) == 0))

    time.sleep(0.5)

    # 2) quota（注意：xpan/api?method=quota 已 404，用 web 风格端点）
    banner("quota（容量）")
    st, d = raw("https://pan.baidu.com/api/quota",
                {"checkfree": "1", "checkunfree": "1", "access_token": TOKEN})
    print("http", st, "| free:", d.get("free"), "errno:", errno_of(d))
    results.append(("quota", errno_of(d) == 0))

    time.sleep(0.5)

    # 3) BFS 逐层找视频（listall 递归无权限 31064，不用）
    banner("list 广度优先找视频（深度<=3，最多60目录）")
    vids = []
    queue = ["/"]
    visited = 0
    while queue and visited < 60 and not vids:
        cur = queue.pop(0)
        visited += 1
        st, _, d = api("file", "list", dir=cur, web="1", limit="1000")
        if errno_of(d) != 0:
            continue
        for it in d.get("list", []):
            if it.get("isdir") == 1:
                if len(queue) < 50:
                    queue.append(it["path"])
            elif it.get("category") == 1 and it.get("size", 0) > 5 * 1048576:
                vids.append(it)
        time.sleep(0.3)
    print("扫描目录数:", visited, "| 视频(>5MB):", len(vids))
    for it in vids[:10]:
        print("  VIDEO %s (%.1fMB)" % (it["path"], it["size"] / 1048576.0))
    results.append(("list 逐层浏览", True))
    time.sleep(0.5)

    if not vids:
        banner("结果汇总")
        for name, okk in results:
            print(("  [PASS] " if okk else "  [FAIL] ") + name)
        return

    video = max(vids, key=lambda i: i["size"])
    print("\n选定视频:", video["path"])

    # 4) filemetas（返回结构是 info[] 不是 list[]）
    banner("filemetas（dlink/缩略图/媒体信息）")
    st, _, d = api("file", "filemetas", fsids=json.dumps([video["fs_id"]]), dlink="1", thumb="1", extra="1")
    fm = None
    if errno_of(d) == 0 and d.get("info"):
        fm = d["info"][0]
        print("http", st, "| thumbs:", json.dumps(fm.get("thumbs"), ensure_ascii=False)[:120])
        print("  width:", fm.get("width"), "| dlink:", (fm.get("dlink") or "")[:60] + "...")
        results.append(("filemetas", True))
    else:
        print("FAIL http", st, json.dumps(d, ensure_ascii=False)[:300])
        results.append(("filemetas", False))

    time.sleep(0.5)

    # 5) streaming（核心：参数用 path，不是 fs_id！）
    banner("streaming（m3u8 480/720/1080，path 参数）")
    seg_url = None
    for typ in ("M3U8_AUTO_480", "M3U8_AUTO_720", "M3U8_AUTO_1080"):
        st, hh, body = get(PAN + "/multimedia?" + urllib.parse.urlencode(
            {"method": "streaming", "access_token": TOKEN, "path": video["path"], "type": typ}))
        text = body[:200].decode("utf-8", "replace")
        if text.lstrip().startswith("#EXTM3U"):
            full = body.decode("utf-8", "replace")
            print("  %s: PASS http %s lines=%d" % (typ, st, full.count("\n")))
            results.append(("streaming " + typ, True))
            if seg_url is None:
                for line in full.splitlines():
                    line = line.strip()
                    if line and not line.startswith("#"):
                        seg_url = line  # 分片已是绝对 URL
                        break
        else:
            print("  %s: FAIL http %s -> %s" % (typ, st, text[:160]))
            results.append(("streaming " + typ, False))
        time.sleep(0.5)

    # 6) 分片拉流（分片 URL 无扩展名，Range 请求预期 206）
    if seg_url:
        banner("m3u8 首个分片拉流")
        st, hh, body = get(seg_url, headers={"Range": "bytes=0-65535"}, timeout=30)
        print("  http %s ct=%s 收到 %d bytes" % (st, hh.get("Content-Type"), len(body)))
        results.append(("分片拉流", st in (200, 206) and len(body) > 0))
    else:
        results.append(("分片拉流", False))

    time.sleep(0.5)

    # 7) dlink 原画直链（UA 按文档设 pan.baidu.com）
    if fm and fm.get("dlink"):
        banner("dlink 原画拉流")
        dl = fm["dlink"] + "&access_token=" + TOKEN
        st, hh, body = get(dl, headers={"User-Agent": "pan.baidu.com", "Range": "bytes=0-65535"})
        print("  带 UA: http %s 收到 %d bytes" % (st, len(body)))
        results.append(("dlink 拉流", st in (200, 206) and len(body) > 0))

    banner("结果汇总")
    for name, okk in results:
        print(("  [PASS] " if okk else "  [FAIL] ") + name)


if __name__ == "__main__":
    main()
