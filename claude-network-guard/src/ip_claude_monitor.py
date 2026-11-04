#!/usr/bin/env python3
"""Persistent read-only-by-default IP/Claude monitor for macOS.

The optional auto-fix only selects the configured proxy in Clash groups.
It never edits credentials, network services, VPN state, or TUN settings.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from ip_claude_check import clash_socket  # noqa: E402


DEFAULTS = {
    "interval_seconds": 60,
    "timeout_seconds": 12,
    "proxy": "http://127.0.0.1:7897",
    "expected_ip": None,
    "expected_proxy": None,
    "groups": ["GLOBAL", "PROXY"],
    "auto_fix": False,
    "notify_recovery": True,
}
LOG_PATH = Path.home() / "Library/Logs/ip-claude-monitor.log"
STATE_PATH = Path.home() / "Library/Application Support/ip-claude-monitor/state.json"


def load_config(path: Path | None) -> dict[str, Any]:
    config = dict(DEFAULTS)
    if path and path.exists():
        config.update(json.loads(path.read_text()))
    if not config["expected_ip"] or not config["expected_proxy"]:
        raise SystemExit("请先执行 python3 setup.py configure")
    return config


def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    line = f"{now()} {message}\n"
    with LOG_PATH.open("a", encoding="utf-8") as stream:
        stream.write(line)
    print(line, end="", flush=True)


def notify(title: str, message: str) -> None:
    if sys.platform != "darwin":
        return
    subprocess.run(
        ["/usr/bin/osascript", "-e", f'display notification {json.dumps(message)} with title {json.dumps(title)}'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def select_proxy(socket_path: str, groups: list[str], proxy: str, timeout: float) -> list[str]:
    import http.client

    class UnixConnection(http.client.HTTPConnection):
        def __init__(self, path: str):
            super().__init__("localhost", timeout=timeout)
            self.path = path

        def connect(self):
            import socket
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(self.timeout)
            self.sock.connect(self.path)

    changed: list[str] = []
    for group in groups:
        conn = UnixConnection(socket_path)
        try:
            body = json.dumps({"name": proxy}).encode()
            conn.request("PUT", f"/proxies/{group}", body=body, headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            response.read()
            if response.status < 300:
                changed.append(group)
        finally:
            conn.close()
    return changed


def run(config: dict[str, Any], once_only: bool = False) -> int:
    import monitor_dashboard as dashboard
    server = None if once_only else dashboard.start_server()
    previous = None
    last_alert = 0
    while True:
        started = time.time()
        dashboard.publish({"checking": True, "expected_ip": config["expected_ip"],
                           "interval": config["interval_seconds"], "auto_fix": config["auto_fix"]})
        repair = "无需纠正"
        try:
            result = dashboard.assess(config)
            if config.get("auto_fix") and result["wrong_groups"]:
                groups = select_proxy(clash_socket(), result["wrong_groups"], config["expected_proxy"], 3)
                result = dashboard.assess(config)
                repair = ("已恢复节点选择并复测：" + ", ".join(groups)) if groups else "节点恢复失败"
        except Exception as exc:
            result = {"status": "error", "summary": "检测异常：" + type(exc).__name__, "checks": [], "clash": {}}
            repair = "未执行"
        finished = time.time()
        next_at = max(finished + 1, started + max(10, int(config["interval_seconds"])))
        history = dashboard.DATA.get("history", [])[-99:] + [{
            "time": finished, "status": result["status"], "summary": result["summary"], "repair": repair}]
        dashboard.publish(dict(result, checking=False, updated_at=finished, next_at=next_at,
                               repair=repair, history=history))
        current = (result["status"], result["summary"])
        if current != previous:
            log(result["status"] + "：" + result["summary"])
        if result["status"] == "error" and (previous != current or finished-last_alert > 600):
            notify("IP / Claude 检测异常", result["summary"])
            last_alert = finished
        elif previous and previous[0] == "error" and result["status"] != "error":
            notify("IP 出口已恢复", result["summary"])
        previous = current
        if once_only:
            return 1 if result["status"] == "error" else 0
        time.sleep(max(1, next_at-time.time()))


def main() -> int:
    parser = argparse.ArgumentParser(description="定时检测 IP、Claude 和 Clash，并在异常时通知/恢复 固定节点")
    parser.add_argument("--config", type=Path, default=HERE / "ip-claude-monitor.json")
    parser.add_argument("--once", action="store_true", help="只检测一轮")
    parser.add_argument("--no-auto-fix", action="store_true", help="本次运行只告警，不切换 Clash 代理组")
    args = parser.parse_args()
    config = load_config(args.config)
    if args.no_auto_fix:
        config["auto_fix"] = False
    return run(config, args.once)


if __name__ == "__main__":
    raise SystemExit(main())
