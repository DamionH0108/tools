"""Loopback-only dashboard and bounded network probes; no credentials or response bodies."""
import concurrent.futures
import ipaddress
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, urlencode
from ip_claude_check import clash_socket, clash_get

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / "Library/Application Support/ip-claude-monitor/state.json"
LOCK = threading.Lock()
DATA = {"checking": True, "updated_at": None, "history": []}

def publish(values):
    with LOCK:
        DATA.update(values)
        STATE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(DATA, ensure_ascii=False))
        tmp.chmod(0o600)
        os.replace(tmp, STATE)

def start_server(port=18765):
    if STATE.exists():
        try:
            old = json.loads(STATE.read_text())
            DATA["history"] = old.get("history", [])[-100:]
        except (ValueError, OSError):
            pass
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("Host") not in {f"127.0.0.1:{port}", f"localhost:{port}"}:
                self.send_error(403)
                return
            path = self.path.split("?")[0]
            if path == "/api/status":
                with LOCK:
                    content = json.dumps(DATA, ensure_ascii=False).encode()
                kind = "application/json"
            elif path == "/":
                content = (ROOT / "dashboard.html").read_bytes()
                kind = "text/html"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", kind + "; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(content)
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

def probe_attempt(name, url, proxy, timeout, kind):
    if url not in ("https://api.ipify.org", "https://www.google.com/generate_204"):
        raise ValueError("未授权的探测目标")
    started = time.monotonic()
    try:
        p = subprocess.run(
            ["/usr/bin/curl", "-q", "-sS", "--max-time", str(timeout), "--connect-timeout", str(min(9, timeout)),
             "--noproxy", "", "--proxy", proxy or "", "--max-filesize", "1000000",
             "-w", "\n%{http_code}", url], capture_output=True, text=True, timeout=timeout+2)
        body, _, status = p.stdout.rpartition("\n")
        code = int(status) if status.isdigit() else 0
        result = {"name": name, "http": code, "ms": round((time.monotonic()-started)*1000), "status": "ok"}
        if p.returncode or not code:
            err = p.returncode
            why = {5:"代理 DNS 解析失败", 6:"域名解析失败", 7:"无法建立连接", 28:"请求超时", 35:"TLS 握手失败", 52:"服务未返回内容", 56:"连接接收失败", 60:"证书校验失败", 63:"响应超过检测大小限制"}.get(err, "未收到有效 HTTP 响应")
            return dict(result, status="error", retryable=err in (5,6,7,28,35,52,56), detail=f"{why}（curl {err}，{result['ms']/1000:.1f} 秒）")
        if kind == "ip":
            try:
                ip = str(ipaddress.ip_address(body.strip()))
            except ValueError:
                return dict(result, status="error", detail="未返回有效 IP")
            return dict(result, ip=ip, detail=ip) if code == 200 else dict(result, status="error", detail=f"HTTP {code}")
        if kind == "trace":
            fields = dict(line.split("=",1) for line in body.splitlines() if "=" in line)
            try:
                ip = str(ipaddress.ip_address(fields.get("ip","")))
            except ValueError:
                return dict(result, status="error", detail=f"未返回出口 IP · HTTP {code}")
            return dict(result, ip=ip, detail=ip, region=fields.get("loc","")) if code == 200 else dict(result, status="error", detail=f"HTTP {code}")
        if url.endswith("/generate_204"):
            return dict(result, status="ok" if code == 204 else "error", detail=f"中立测速站 HTTP {code}")
        challenge = "just a moment" in body.lower() or "cf-chl-" in body.lower()
        if challenge or code == 403:
            return dict(result, status="warning", detail=f"HTTP {code} · 验证页或访问受限，需浏览器确认")
        if code == 429:
            return dict(result, status="warning", detail="HTTP 429 · 请求受限")
        if code >= 400:
            return dict(result, status="error", detail=f"HTTP {code}")
        return dict(result, detail=f"HTTP {code} · 网站可达，未验证登录或对话")
    except subprocess.TimeoutExpired:
        return {"name": name, "status": "error", "detail": "检测进程超时", "retryable": True, "ms": round((time.monotonic()-started)*1000)}
    except OSError:
        return {"name": name, "status": "error", "detail": "探测失败或超时", "ms": round((time.monotonic()-started)*1000)}

def probe(name, url, proxy, timeout, kind):
    first = probe_attempt(name, url, proxy, timeout, kind)
    if not first.get("retryable"):
        return first
    time.sleep(1)
    second = probe_attempt(name, url, proxy, timeout, kind)
    second["detail"] += "；复测" + ("仍失败" if second["status"] == "error" else "已收到响应") + "（首次：" + first["detail"] + "）"
    return second

def compare_routes(sock, upstream, exit_node):
    # Same independent target, same time; never change the active selector.
    query = urlencode({"url": "https://www.google.com/generate_204", "timeout": 7000})
    def test(node):
        try:
            reply = clash_get(sock, "/proxies/" + quote(node, safe="") + "/delay?" + query, 9)
            return "通" if isinstance(reply, dict) and isinstance(reply.get("delay"), int) else "未知"
        except OSError as exc:
            return "超时" if str(exc) == "HTTP 504" else "未知"
        except (ValueError, EOFError):
            return "未知"
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        a, b = pool.map(test, (upstream, exit_node))
    advice = {
        ("通", "超时"): "优先排查到 固定节点 的线路及其出口",
        ("超时", "超时"): "先检查公司网络到 上游节点 的连接",
        ("通", "通"): "两条线路此刻均可达测速站，继续观察原检测项",
    }.get((a, b), "本轮对照不足以定位")
    return f"线路对照：上游节点 {a}，经 固定节点 {b}。{advice}。"

def assess(config):
    urls = [
        ("公网出口", "https://api.ipify.org", "ip"),
        ("公网连通", "https://www.google.com/generate_204", "page"),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(pool.map(lambda x: probe(x[0], x[1], config["probe_listener"], float(config["timeout_seconds"]), x[2]), urls))
    expected = config["expected_ip"]
    for row in rows[:1]:
        if row.get("ip") and row["ip"] != expected:
            row.update(status="error", detail=f"{row['ip']} · 与预期不一致")
    wrong_groups = []
    clash = {"status": "error", "detail": "无法读取 Clash", "tun": None, "mode": "未知", "selected": {}}
    guard = {"name":"Claude 分流策略", "status":"error", "detail":"无法核实保护规则"}
    try:
        sock = clash_socket()
        if not sock:
            raise OSError("socket unavailable")
        cfg = clash_get(sock, "/configs", 2)
        proxies = clash_get(sock, "/proxies", 2)["proxies"]
        selected = {g: proxies.get(g, {}).get("now") for g in config["groups"]}
        wrong_groups = [g for g in config["groups"] if g in proxies and
                        config["expected_proxy"] in proxies[g].get("all", []) and
                        selected[g] != config["expected_proxy"]]
        clash = {"status": "ok", "detail": "Clash 已连接", "mode": cfg.get("mode"),
                 "tun": cfg.get("tun", {}).get("enable"), "selected": selected}
        rules = clash_get(sock, "/rules", 3)["rules"]
        domains = set("anthropic.com anthropic.ai claude.ai claude.com claudeusercontent.com claude.site claudemcpcontent.com".split())
        first = rules[:len(domains)]
        if (cfg.get("mode") == "rule" and clash["tun"] and
                {r.get("payload") for r in first} == domains and
                all(r.get("type") == "DomainSuffix" and r.get("proxy") == config["expected_proxy"]
                    and not (r.get("extra") or {}).get("disabled") for r in first)):
            guard.update(status="ok", detail="已识别域名仅走 固定节点；不探测 Claude")
        if wrong_groups or not cfg.get("tun", {}).get("enable") or cfg.get("mode") != "rule" or any(not v for v in selected.values()):
            clash.update(status="warning", detail="模式、TUN 或节点选择需要检查")
    except (OSError, ValueError, KeyError):
        pass
    rows.insert(1, guard)
    state = "error" if any(r["status"]=="error" for r in rows) or clash["status"]=="error" else (
        "warning" if any(r["status"]=="warning" for r in rows) or clash["status"]=="warning" else "ok")
    summary = "；".join(r["name"]+"："+r["detail"] for r in rows if r["status"]!="ok") or clash["detail"]
    if (clash["status"] == "ok" and config.get("upstream") in proxies and
            config["expected_proxy"] in proxies and any(r["status"] == "error" and r.get("retryable") for r in rows)):
        summary = compare_routes(sock, config["upstream"], config["expected_proxy"]) + summary
    return {"status": state, "checks": rows, "clash": clash, "wrong_groups": wrong_groups,
            "summary": summary}
