"""One fresh read-only assessment; no daemon, state writes, or group changes."""
import json, sys
from pathlib import Path
from monitor_dashboard import assess
def run(path):
    cfg=json.loads(Path(path).read_text())
    cfg.setdefault("probe_listener","http://127.0.0.1:1133")
    cfg.setdefault("timeout_seconds",8)
    cfg.setdefault("groups",[])
    result=assess(cfg)
    return result["status"]=="ok",result["summary"]
if __name__=="__main__":
    try:
        ok,detail=run(sys.argv[1])
        print(("通过：" if ok else "未通过：")+detail)
    except Exception:
        print("检测未完成：请检查配置文件或 Clash 服务。");ok=False
    sys.exit(0 if ok else 1)
