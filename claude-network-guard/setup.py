"""Set up a per-user macOS monitor without importing any proxy credentials."""
from pathlib import Path
import argparse, ipaddress, json, os, plistlib, shutil, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parent
LOCAL = ROOT / "local"
TARGET = Path.home() / "Library/Application Support/ip-claude-monitor"
APP = Path.home() / "Applications/IPClaudePanel.app"
LABEL = "com.codex.ip-claude-monitor"
AGENT = Path.home() / f"Library/LaunchAgents/{LABEL}.plist"
DOMAINS = "anthropic.com anthropic.ai claude.ai claude.com claudeusercontent.com claude.site claudemcpcontent.com".split()
def configure():
    node = input("固定出口的 Clash 节点名（实际节点，不是策略组）：").strip()
    if not node: raise SystemExit("节点名不能为空")
    ip = str(ipaddress.ip_address(input("预期的固定公网 IP：").strip()))
    port = int(input("专用本机监听端口 [1133]：").strip() or "1133")
    if not 1024 <= port <= 65535: raise SystemExit("端口必须在 1024–65535 之间")
    upstream = input("上游节点名（没有则回车）：").strip()
    config = dict(expected_proxy=node, expected_ip=ip, probe_listener=f"http://127.0.0.1:{port}", upstream=upstream or None, groups=[], auto_fix=False)
    LOCAL.mkdir(exist_ok=True,mode=0o700)
    (LOCAL/"ip-claude-monitor.json").write_text(json.dumps(config, ensure_ascii=False, indent=2))
    js = """function protectClaude(c) {
  const name = NODE, port = PORT;
  const exit = (c.proxies || []).some(p => p.name === name && !['direct','reject','dns','pass'].includes(String(p.type).toLowerCase())) ? name : 'REJECT';
  const first = DOMAINS.map(d => 'DOMAIN-SUFFIX,' + d + ',' + exit);
  const listeners = c.listeners || [];
  const pinned = {name:'TeamClaudeGuard', type:'http', listen:'127.0.0.1', port:port, proxy:exit};
  if (listeners.some(l => l.name !== pinned.name && Number(l.port) === port)) throw Error('专用端口已占用，请换一个端口');
  c.listeners = [...listeners.filter(l => l.name !== pinned.name), pinned];
  c.rules = [...first, ...(c.rules || []).filter(r => !first.includes(r))];
  return c;
}
function main(config) { return protectClaude(config); }
""".replace("DOMAINS.map",json.dumps(DOMAINS)+".map").replace("port = PORT","port = "+str(port)).replace("name = NODE","name = "+json.dumps(node))
    (LOCAL/"clash-guard.js").write_text(js)
    print("已生成 local/clash-guard.js，请按 README 应用规则。")
def install():
    if sys.platform != "darwin": raise SystemExit("需要 macOS")
    local_config=LOCAL/"ip-claude-monitor.json"
    if not local_config.exists(): raise SystemExit("请先 configure")
    marker=TARGET/".team-install"
    if any(x.exists() for x in [TARGET,APP,AGENT]) and not marker.exists():
        raise SystemExit("已存在其他版本的监控。为防止覆盖，本次未安装。")
    with tempfile.TemporaryDirectory() as tmp:
        app=Path(tmp)/"IPClaudePanel.app"; mac=app/"Contents/MacOS"; mac.mkdir(parents=True)
        shutil.copy2(ROOT/"panel/Info.plist",app/"Contents")
        (app/"Contents/Resources").mkdir()
        shutil.copy2(ROOT/"panel/egress-test.html",app/"Contents/Resources")
        shutil.copy2(ROOT/"panel/morelogin-guide.html",app/"Contents/Resources")
        shutil.copy2(ROOT/"panel/AppIcon.icns",app/"Contents/Resources")
        shutil.copytree(ROOT/"src", app/"Contents/Resources/monitor",ignore=shutil.ignore_patterns("__pycache__"))
        subprocess.run(["xcrun","swiftc",str(ROOT/"panel/IPClaudePanel.swift"),str(ROOT/"panel/SetupWizard.swift"),"-o",str(mac/"IPClaudePanel")],check=True)
        subprocess.run(["codesign","--force","--sign","-",str(app)],check=True)
        TARGET.mkdir(exist_ok=True,parents=True);marker.touch()
        for f in (ROOT/"src").iterdir():
            if f.is_file(): shutil.copy2(f,TARGET)
        shutil.copy2(local_config,TARGET)
        APP.parent.mkdir(exist_ok=True);shutil.copytree(app,APP,dirs_exist_ok=True)
    AGENT.parent.mkdir(parents=True,exist_ok=True)
    service=f"gui/{os.getuid()}"
    subprocess.run(["launchctl","bootout",service+"/"+LABEL],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    AGENT.write_bytes(plistlib.dumps(dict(Label=LABEL,ProgramArguments=[sys.executable,str(TARGET/"ip_claude_monitor.py")],RunAtLoad=True,KeepAlive=True,StandardErrorPath=str(TARGET/"service.log"))))
    subprocess.run(["launchctl","bootstrap",service,str(AGENT)],check=True)
    subprocess.run(["open",str(APP)],check=True)
if __name__=="__main__":
    args=argparse.ArgumentParser();args.add_argument("command",choices=["configure","install"])
    {"configure":configure,"install":install}[args.parse_args().command]()
