"""Interactive, narrowly scoped Claude Code cleanup. No network or sudo."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ASSETS = ('skills','agents','commands','hooks','rules','CLAUDE.md','plugins','settings.json')
STATE = ('backups','telemetry','statsig','projects','sessions','history.jsonl','file-history','.credentials.json')
SERVICES = ('Claude Code-credentials','Claude Safe Storage')

def targets(home):
    root = home/'.claude'
    if root.is_symlink() or (root.exists() and not root.is_dir()):
        raise ValueError('~/.claude 不是普通目录，已停止。')
    files = [home/name for name in ('.claude.json','.claude.json.backup','.claude-local-oauth.json','.anthropic')]
    files.extend(sorted(home.glob('.claude.json.backup.*')))
    files.extend(root/name for name in STATE)
    return [p for p in files if os.path.lexists(p)]

def backup(home, dest):
    for name in ASSETS:
        src = home/'.claude'/name
        if src.is_symlink():
            (dest/name).symlink_to(os.readlink(src))
        elif src.is_dir():
            shutil.copytree(src,dest/name,symlinks=True)
        elif src.is_file():
            shutil.copy2(src,dest/name)

def snapshot(home,dest):
    src = home/'.claude.json'
    if src.is_symlink(): raise ValueError('主配置是符号链接，已停止。')
    result = {}
    if src.exists():
        obj = json.loads(src.read_text())
        for k in ('userID','machineID'):
            value = obj.get(k)
            if isinstance(value,str) and value:
                result[k] = hashlib.sha256(value.encode()).hexdigest()
    (dest/'identifier-digests.json').write_text(json.dumps(result))
    return bool(result)

def remove(paths):
    for p in paths:
        if p.is_symlink() or not p.is_dir(): p.unlink()
        else: shutil.rmtree(p)

def check_processes():
    names=subprocess.check_output(['/bin/ps','-axo','comm='],text=True).splitlines()
    if any(re.search(r'(/Claude\.app/|(^|/)claude(?:-code)?$|(^|/)Claude Helper)',n.strip(),re.I) for n in names):
        raise ValueError('请先保存工作、退出 Claude 桌面端和所有 CLI/IDE 中的 Claude 会话，再重试。')

def key(service,delete=False):
    # Look up metadata only. Never request the secret value (-w/-g).
    cmd='delete-generic-password' if delete else 'find-generic-password'
    p=subprocess.run(['/usr/bin/security',cmd,'-s',service],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if p.returncode not in (0,44): raise ValueError('钥匙串操作失败或已取消：'+service)
    return p.returncode==0

def main():
    home=Path.home()
    if os.geteuid()==0 or not os.isatty(0): raise ValueError('请从面板打开，以当前用户在终端确认。')
    check_processes()
    files=targets(home)
    keys=[s for s in SERVICES if key(s)]
    print('本次范围：Claude Code 已知账号状态、会话历史及指定钥匙串条目。\n浏览器、IDE、Clash、未知目录与其他应用不在范围内。')
    for p in files: print('  ~/'+str(p.relative_to(home)))
    for k in keys: print('  钥匙串：'+k)
    if not files and not keys: print('没有发现上述本地项目，无需清理。'); return
    print('旧会话、登录信息和历史不会备份，删除后无法由本工具恢复。\n将先备份并保留个人配置（skills、commands、plugins 等）；请先关闭相关进程。')
    if input('输入 SWITCH ACCOUNT 执行，其余输入取消：')!='SWITCH ACCOUNT':
        print('已取消，未更改。');return
    check_processes()
    if targets(home)!=files: raise ValueError('待清理列表已变化，请重新预览。')
    dest=Path(tempfile.mkdtemp(prefix='Claude-setup-backup-',dir=home))
    print('个人配置备份位置：',dest)
    saved=snapshot(home,dest)
    assets=dest/'personal';assets.mkdir()
    backup(home,assets)
    check_processes()
    remove(files)
    for k in keys:key(k,True)
    if targets(home) or any(key(k) for k in SERVICES): raise ValueError('仍有目标项残留，请按手册复核。')
    print('已复查：列出的本地项已清理，个人配置仍在原处。')
    print('已保存可用标识的摘要。' if saved else '没有可用的旧标识，无法进行新旧比对。')
    print('旧浏览器站点数据、可选 IDE 数据及登录后比对尚未验收。')
if __name__=='__main__':
    try: main()
    except (OSError,ValueError,EOFError,subprocess.SubprocessError) as err:
        raise SystemExit('已停止（若已开始删除，请检查残留项）：'+str(err))
