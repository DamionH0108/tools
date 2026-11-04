#!/usr/bin/env python3
"""Read-only local proxy, IP, DNS and Claude availability checker.

Examples:
  python3 ip_claude_check.py
  python3 ip_claude_check.py --proxy http://127.0.0.1:7897 --json
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from http.client import HTTPConnection, HTTPSConnection
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener



IP_URL = "https://api.ipify.org"

GOOGLE_URL = "https://www.google.com/generate_204"


@dataclass
class Check:
    name: str
    ok: bool
    status: int | None = None
    elapsed_ms: int | None = None
    detail: str = ""
    error: str = ""


def elapsed(start: float) -> int:
    return round((time.monotonic() - start) * 1000)


def proxy_opener(proxy: str | None):
    # An empty ProxyHandler deliberately ignores HTTP(S)_PROXY from the shell.
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, *args):
            return None
    return build_opener(NoRedirect(), ProxyHandler({} if not proxy else {"http": proxy, "https": proxy}))


def fetch(url: str, proxy: str | None, timeout: float) -> tuple[int, str, int]:
    if url not in (IP_URL, GOOGLE_URL):
        raise ValueError("未授权的探测目标")
    start = time.monotonic()
    req = Request(url, headers={"User-Agent": "ip-claude-check/1.0"})
    try:
        with proxy_opener(proxy).open(req, timeout=timeout) as response:
            body = response.read(64 * 1024).decode("utf-8", "replace")
            return response.status, body, elapsed(start)
    except HTTPError as exc:
        body = exc.read(64 * 1024).decode("utf-8", "replace")
        return exc.code, body, elapsed(start)


def check_http(name: str, url: str, proxy: str | None, timeout: float, expected: set[int]) -> Check:
    try:
        status, body, ms = fetch(url, proxy, timeout)
        return Check(name, status in expected, status, ms, body[:300].replace("\n", " "))
    except (URLError, OSError, TimeoutError, ssl.SSLError) as exc:
        return Check(name, False, elapsed_ms=None, error=str(getattr(exc, "reason", exc)))


def system_proxy() -> str | None:
    if sys.platform != "darwin":
        return None
    try:
        text = subprocess.check_output(["/usr/sbin/scutil", "--proxy"], text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return None
    enabled = re.search(r"HTTPSEnable\s*:\s*1", text) or re.search(r"HTTPEnable\s*:\s*1", text)
    host = re.search(r"HTTPSProxy\s*:\s*(\S+)", text) or re.search(r"HTTPProxy\s*:\s*(\S+)", text)
    port = re.search(r"HTTPSPort\s*:\s*(\d+)", text) or re.search(r"HTTPPort\s*:\s*(\d+)", text)
    if enabled and host and port:
        return f"http://{host.group(1)}:{port.group(1)}"
    return None


def clash_socket() -> str | None:
    candidates = [
        f"/var/run/clash-verge-service/users/{os.getuid()}/verge-mihomo.sock",
        "/tmp/verge/verge-mihomo.sock",
    ]
    return next((path for path in candidates if Path(path).exists()), None)


class UnixHTTPConnection(HTTPConnection):
    def __init__(self, socket_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def clash_get(socket_path: str, endpoint: str, timeout: float) -> Any:
    conn = UnixHTTPConnection(socket_path, timeout)
    try:
        conn.request("GET", endpoint)
        response = conn.getresponse()
        if response.status >= 400:
            raise OSError(f"HTTP {response.status}")
        return json.loads(response.read().decode("utf-8"))
    finally:
        conn.close()


def clash_status(socket_path: str | None, timeout: float) -> list[Check]:
    if not socket_path:
        return [Check("Clash 运行状态", False, detail="未找到 Mihomo Unix socket")]
    try:
        config = clash_get(socket_path, "/configs", timeout)
        proxies = clash_get(socket_path, "/proxies", timeout).get("proxies", {})
        selected = {k: v.get("now") for k, v in proxies.items() if k in {"GLOBAL", "PROXY", "Proxy"}}
        detail = f"mode={config.get('mode')} tun={config.get('tun', {}).get('enable')} selected={selected}"
        return [Check("Clash 运行状态", True, detail=detail)]
    except (OSError, ValueError, KeyError) as exc:
        return [Check("Clash 运行状态", False, error=str(exc))]


def run(proxy: str | None, timeout: float, include_direct: bool, socket_path: str | None) -> list[Check]:
    checks: list[Check] = clash_status(socket_path, timeout)
    jobs = [("IP 出口（代理）", IP_URL, proxy, {200}), ("Google 连通（代理）", GOOGLE_URL, proxy, {204})]
    if include_direct:
        jobs.append(("IP 出口（直连对照）", IP_URL, None, {200}))
    with concurrent.futures.ThreadPoolExecutor() as pool:
        jobs = [pool.submit(check_http, name, url, route, timeout, codes) for name,url,route,codes in jobs]
        checks.extend(j.result() for j in jobs)
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description="检查当前 IP、Clash 和中立站点连通性（只读）")
    parser.add_argument("--proxy", help="HTTP 代理，例如 http://127.0.0.1:7897；默认读取 macOS 系统代理")
    parser.add_argument("--timeout", type=float, default=12, help="单项超时秒数，默认 12")
    parser.add_argument("--no-direct", action="store_true", help="跳过直连对照，减少失败请求")
    parser.add_argument("--clash-socket", help="Mihomo Unix socket 路径")
    parser.add_argument("--json", action="store_true", help="输出 JSON，便于脚本或自动化读取")
    args = parser.parse_args()
    proxy = args.proxy or system_proxy()
    socket_path = args.clash_socket or clash_socket()
    checks = run(proxy, args.timeout, not args.no_direct, socket_path)
    payload = {"proxy": proxy, "checks": [asdict(item) for item in checks], "ok": all(item.ok for item in checks)}
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"检测代理：{proxy or '未检测到系统代理'}")
        for item in checks:
            mark = "通过" if item.ok else "失败"
            timing = f"，{item.elapsed_ms} ms" if item.elapsed_ms is not None else ""
            detail = item.detail or item.error
            print(f"[{mark}] {item.name}{timing}: {detail}")
        print("\n结论：" + ("当前检测项全部通过" if payload["ok"] else "有检测项失败，请根据失败项处理"))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
