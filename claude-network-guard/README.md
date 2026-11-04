# Claude 出口守卫 · macOS
每分钟通过专用代理端口检查固定出口，在 Mac 右上角显示评分，点击可看扣分原因。监控仅访问 ipify 和 Google 的连通性检查地址；Claude 分流由 Clash 执行，监控不访问 Claude。无需填写代理密码。

## 第一次使用：从零搭建
解压团队提供的 Claude-Guard-macOS.zip，将 IPClaudePanel.app 拖到“应用程序”再打开。首次自动显示向导；已有用户可从菜单栏 IP → 从零搭建，或详情窗口左上角进入。支持 Intel 和 Apple 芯片，macOS 12+。此包使用本地签名，未经 Apple 公证；如公司策略禁止运行，请让团队管理员签名分发。
向导第一步是「旧电脑环境清理」。新电脑或继续使用当前账号可直接跳过；需要换号的旧电脑可从向导打开团队手册，并在旧浏览器配置文件中分别移除 claude.ai 与 anthropic.com 的站点数据。普通系统缓存和日志无需清理。涉及 CLI、桌面端或钥匙串时，先看手册的备份范围与历史丢失说明；向导不会自动删除。

第二步从 IPRoyal ISP 购买、提取 SOCKS5 信息与交付参数检查开始；已有代理可跳过。随后进入 Clash 配置，顶部可切换 MoreLogin 浏览器、HubStudio 云真机。上游代理、IPRoyal、预期 IP 和本机端口可直接填写；生成文件后手动导入为新订阅。自动验收只更新状态，不会跳页。常驻监控需要 Python 3.9+。
MoreLogin → Google 登录 → HubStudio 云真机属于同一流程，页面提供操作入口，无需逐项打勾。尚未对接云端出口或账号状态。账号验证和订阅在相应平台完成。
源码构建：在装有 Xcode 工具链的 Mac 上运行 `./build-mac.sh`，得到本地签名的通用应用包。

## 已有 Clash 节点：命令行安装
前提：已有可用的固定出口节点、Clash Verge Rev（Mihomo 内核，规则模式并开启 TUN）、Python 3.10+ 和 Xcode Command Line Tools。Python 仅用标准库。后台使用本机 18765 端口。
1. 进入仓库，运行 `python3 setup.py configure`，填写自己的出口节点名和预期 IP；选择未占用的本机代理端口。个人配置只存入被 Git 忽略的 local/。
2. 在 Clash Verge Rev 的全局扩展脚本中应用 `local/clash-guard.js`，保存并重载配置。如果已有扩展，不要覆盖：保留原 main，把 protectClaude 函数加入脚本，并在原 main 最后对最终配置调用它，例如 `return protectClaude(config);`。如果订阅扩展随后重排规则，需在其最后同样调用。工具不会自动覆盖订阅或切换代理组。
3. 运行 `python3 setup.py install`。它现场编译原生面板、安装用户级登录后台并打开面板；不需要 sudo。以后可从 ~/Applications 打开 IPClaudePanel。要让悬浮窗也随登录打开，把该应用加入系统登录项。
4. 等第一轮检测完成，核对实测出口 IP 与预期一致，并确认“Claude 分流规则”显示“已限定”。未确认时不要把当前配置当成已受保护。≥85 分为合格；分数不代表 Claude 账号或服务可用。

## 保护范围
在 Clash 接管且使用规则模式时，匹配的 Claude / Anthropic 域名仅走指定实际节点；节点不存在则 REJECT，节点断线不回退直连。非匹配流量保留原规则。工具检查七条规则的优先级、TUN 状态及专用端口出口。退出 Clash、绕开代理、自建 API 网关不在此保护范围。供应商在同一节点上更换出口 IP 时只能告警，不会强制断网。可选的上游对照只在公网检测失败时运行。

## 更新和卸载
更新：备份本地配置，拉取代码，重新 configure，按步骤更新 Clash 脚本并执行 install；退出再打开原生面板。若发现同名个人旧版，安装器会停止，不覆盖旧版。
卸载：退出面板，运行 `launchctl bootout "gui/$(id -u)/com.codex.ip-claude-monitor"`，然后移除 ~/Library/LaunchAgents/com.codex.ip-claude-monitor.plist、~/Applications/IPClaudePanel.app、~/Library/Application Support/ip-claude-monitor 以及自己添加的登录项。要取消代理限制，在 Clash 移除新增扩展并重载。检测记录在 ~/Library/Logs/ip-claude-monitor.log，仅保存在本机。

上游支持 Clash 兼容的 HTTP(S) 订阅。在「Clash」页选「订阅链接」，粘贴后生成配置并导入 Clash，在 Team-Upstream 选择节点。订阅仅提供上游节点；最终出口仍是 IPRoyal。生成的配置含订阅令牌和代理凭据，仅供本人保存。
