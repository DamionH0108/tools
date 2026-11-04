import AppKit
import Darwin

// All setup fields are native controls. Secrets never pass through the dashboard.
private final class WizardDocument: NSView { override var isFlipped: Bool { true } }
final class SetupWizard: NSObject {
    private let win = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:395), styleMask:[.titled,.closable,.resizable], backing:.buffered,defer:false)
    private let stack = NSStackView()
    private var fields = [String:NSTextField]()
    private let proto = NSPopUpButton()
    private let result = NSTextField(wrappingLabelWithString:"")
    private var generated: URL?
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ip-claude-monitor")
    private let domains = "anthropic.com anthropic.ai claude.ai claude.com claudeusercontent.com claude.site claudemcpcontent.com".components(separatedBy:" ")
    private let upstream = "Team-Upstream", exit = "IPRoyal-US-ISP"
    override init() {
        super.init()
        win.title="团队搭建 · Claude 出口守卫"; win.isReleasedWhenClosed=false
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; win.contentView=scroll
        let doc=WizardDocument(); scroll.documentView=doc; doc.translatesAutoresizingMaskIntoConstraints=false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=10; stack.translatesAutoresizingMaskIntoConstraints=false; doc.addSubview(stack)
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),stack.topAnchor.constraint(equalTo:doc.topAnchor,constant:20), stack.leadingAnchor.constraint(equalTo:doc.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:doc.trailingAnchor,constant:-24),stack.bottomAnchor.constraint(equalTo:doc.bottomAnchor,constant:-20)])
        if let id=UserDefaults.standard.string(forKey:"teamFlowGenerated"), UUID(uuidString:id) != nil {
            let dir=root.appendingPathComponent("Setup/"+id)
            if FileManager.default.fileExists(atPath:dir.appendingPathComponent("monitor.json").path){generated=dir}
        }
        renderFlow()
    }
    private var subscriptionMode=true
    private var stage=0
    private var ticker: Timer?
    private var draft=[String:String]()
    private func go(_ n:Int){
        for (k,f) in fields where k != "upURI" {draft[k]=f.stringValue}
        stage=n;renderFlow()
    }
    @objc private func selectStage(_ sender:NSSegmentedControl){go(sender.selectedSegment)}
    @objc private func browserStep(){go(2)}
    @objc private func cloudStep(){go(3)}
    private let health = NSTextField(wrappingLabelWithString:"等待读取监控结果…")
    private let guide="https://tssoft.atlassian.net/wiki/spaces/AI2/pages/2667121483/Claude"
    private let cloudGuide="https://tssoft.atlassian.net/wiki/spaces/AI2/pages/1979711914/Claude"
    private func link(_ label:String,_ url:String){
        let b=NSButton(title:label,target:self,action:#selector(openLink(_:)));b.identifier=NSUserInterfaceItemIdentifier(url)
        stack.addArrangedSubview(b)
    }
    @objc private func openLink(_ b:NSButton){if let s=b.identifier?.rawValue,let u=URL(string:s){NSWorkspace.shared.open(u)}}
    private func renderFlow(){
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v);v.removeFromSuperview() }
        fields.removeAll();result.stringValue=""
        let nav=NSSegmentedControl(labels:["1  IPRoyal 固定 IP","2  Clash 配置","3  MoreLogin","4  HubStudio"],trackingMode:.selectOne,target:self,action:#selector(selectStage(_:)))
        nav.selectedSegment=stage;stack.addArrangedSubview(nav)
        if stage==0 {
            title("获取 IPRoyal 固定出口")
            note("团队已分配固定 IP？不用重复购买，可以直接进入 Clash 配置。首次购买按下面三步操作。")
            note("① 在 IPRoyal 登录，左侧选 ISP → Create a new order。选择 ISP Proxies（独享静态住宅 IP），不要选轮换住宅代理。")
            link("打开 IPRoyal · ISP 固定 IP","https://iproyal.com/isp-proxies/")
            note("② 选择团队要求的地区、数量和期限。要沿用同一个 IP，不要开启 Fresh IPs every renewal（续期更换 IP）。核对订单金额和续费选项后，在官网付款。")
            note("③ 打开已交付的 ISP 订单，协议选 SOCKS5，取出服务器、端口和代理认证信息。这里要填代理用户名和密码，不是 IPRoyal 网站的登录密码。")
            link("看官方购买和提取参数图解","https://help.iproyal.com/en/articles/7955587-how-to-use-isp-proxies")
            row("代理服务器","ipHost","主机名或 IP","ipPort","SOCKS5 端口")
            row("代理认证","ipUser","代理用户名","ipPass","代理密码",true)
            single("固定出口","expected","订单分配的出口 IP")
            for (k,v) in draft {fields[k]?.stringValue=v}
            button("检查交付参数，带入 Clash →",#selector(checkDelivery))
            button("已配置或由团队分配 · 直接查看 Clash",#selector(skipPurchase))
            note("本步检查字段格式，不代表订单已支付或线路已通。下一步将从专用端口检测实际出口。")
        } else if stage==1 {
            title("配置 Clash 固定出口")
            stack.addArrangedSubview(health);health.preferredMaxLayoutWidth=550
            note("上游是连接 IPRoyal 之前经过的代理节点（例如 TrueSight）。这里填上游自己的服务器和认证信息。")
            button("打开 Clash · 未安装则前往官网下载",#selector(openClash))
            let mode=NSSegmentedControl(labels:["订阅链接","单节点 / 手填"],trackingMode:.selectOne,target:self,action:#selector(changeSource(_:)))
            mode.selectedSegment=subscriptionMode ? 0 : 1;stack.addArrangedSubview(mode)
            if subscriptionMode {
                let input=NSSecureTextField();input.placeholderString="粘贴服务商提供的 Clash 订阅 URL（https://…）";input.widthAnchor.constraint(equalToConstant:440).isActive=true
                fields["subscription"]=input;stack.addArrangedSubview(input)
                note("生成配置并导入 Clash 后，在 Team-Upstream 组中选择订阅节点。Claude 最终仍走 IPRoyal，不用逐个填写上游账号和端口。")
            } else {
            let uri=NSSecureTextField();uri.placeholderString="协议://用户名:密码@服务器:端口";uri.widthAnchor.constraint(equalToConstant:320).isActive=true
            let parse=NSButton(title:"解析并填入",target:self,action:#selector(importUpstream))
            stack.addArrangedSubview(NSStackView(views:[NSTextField(labelWithString:"上游节点链接"),uri,parse]));fields["upURI"]=uri
            if proto.numberOfItems==0 {proto.addItems(withTitles:["HTTP","HTTPS","SOCKS5"])}
            let protocols=NSStackView(views:[NSTextField(labelWithString:"上游协议"),proto]);stack.addArrangedSubview(protocols)
            row("上游代理","upHost","服务器","upPort","端口")
            row("上游认证","upUser","用户名（可选）","upPass","密码",true)
            }
            if deliveryValid {
                note("沿用第 1 步：SOCKS5　"+value("ipHost")+":"+value("ipPort")+"　·　固定出口 "+value("expected"))
            } else {
                note("使用现有配置可直接检测。若要生成新配置，请先在第 1 步填写 IPRoyal 资料。")
            }
            button(deliveryValid ? "修改第 1 步的 IPRoyal 资料" : "前往第 1 步填写 IPRoyal 资料",#selector(editDelivery))
            single("本机监听端口","port","例如 1133")
            note("1133 是本工具默认的本机入口。MoreLogin 在同一台 Mac 上连接 127.0.0.1:1133。仅端口冲突时才需更改，两处要一致。")
            if draft["port"]==nil {fields["port"]?.stringValue="1133"}
            for (k,v) in draft {fields[k]?.stringValue=v}
            note("分流：Claude 域名 → IPRoyal（经上游）；其他流量 → 直连。已有公司分流请先合并。")
            let create=NSButton(title:"生成 Clash 配置文件…",target:self,action:#selector(generate));create.isEnabled=deliveryValid;stack.addArrangedSubview(create)
            if generated != nil {button("在访达中显示上次配置",#selector(reveal))}
            note("在 Clash 中将文件导入为新订阅，选用规则模式并开启 TUN，再启用监控。")
            button("启用监控",#selector(enable))
            button("完成 Clash 配置 · 立即检测",#selector(checkLocal(_:)))
            button("下一步：MoreLogin 浏览器 →",#selector(browserStep))
        } else if stage==2 {
            title("让 MoreLogin 浏览器使用固定出口")
            button("看图操作 · 五张真实截图",#selector(openPictureGuide))
            note("1   在这台 Mac 上打开 MoreLogin。编辑团队分给你的环境；还没有环境，就选「新建环境 → 浏览器环境 → 高级创建」。")
            button("打开 MoreLogin",#selector(openBrowser))
            if let settings=browserRoute() {
                note("2   在「代理设置」选择自有代理，按下列值填写并保存。先点 proxy detection，对照 Egress IP，再启动环境。")
                note("协议：HTTP     主机：127.0.0.1     端口："+String(settings.port)+"     用户名和密码：留空")
                note("3   下方按钮复制一次性检测页到剪贴板。在 MoreLogin 环境的地址栏粘贴并回车，即会发起一次实测并显示结果。预期："+settings.ip)
                button("完成配置 · 检测浏览器出口",#selector(copyCheckURL))
                let ip=NSTextField();ip.placeholderString="粘贴 MoreLogin 窗口里显示的 IP";ip.preferredMaxLayoutWidth=350
                let compare=NSButton(title:"比对出口",target:self,action:#selector(compareBrowserIP))
                stack.addArrangedSubview(NSStackView(views:[ip,compare]));ip.widthAnchor.constraint(equalToConstant:310).isActive=true
                fields["browserIP"]=ip
                note("一致后，在同一个 MoreLogin 窗口登录 Google，再进入 HubStudio。若不一致，先检查代理设置。")
            } else {
                note("还没有可用的本机代理参数。先到「Clash 配置」生成配置、导入并启用监控，再回来。")
            }
            link("MoreLogin 官方操作示例","https://support.morelogin.com/en/articles/10198892-advanced-create")
            button("下一步：HubStudio 云真机 →",#selector(cloudStep))
        } else if stage==3 {
            title("在 HubStudio 中连接云真机")
            note("打开分配给你的云真机，按教程设置同一固定出口，再在设备内完成登录。工具只能验收本机，不能替你判断云真机是否已连通。")
            button("打开 HubStudio",#selector(openCloud))
            link("查看团队云真机教程",cloudGuide)
            note("请将检测页文本传到云真机，在设备内的浏览器地址栏粘贴并回车。不要在 Mac 上打开。若设备不支持检测页，打开 api.ipify.org 并将 IP 粘回比对。")
            button("完成配置 · 检测云真机出口",#selector(copyCheckURL))
            let cloud=NSTextField();cloud.placeholderString="备用：云真机中查到的 IP";fields["browserIP"]=cloud
            stack.addArrangedSubview(NSStackView(views:[cloud,NSButton(title:"比对云真机出口",target:self,action:#selector(compareBrowserIP))]))
            cloud.widthAnchor.constraint(equalToConstant:300).isActive=true
            button("返回 MoreLogin 设置",#selector(browserStep))
        }
        result.textColor = .secondaryLabelColor; stack.addArrangedSubview(result)
        result.widthAnchor.constraint(lessThanOrEqualTo:stack.widthAnchor).isActive=true
        win.setContentSize(NSSize(width:640,height:stage==0 || stage==1 ? 680 : stage==2 ? 585 : 490))
        refreshHealth()
    }
    @objc private func changeSource(_ sender:NSSegmentedControl){
        subscriptionMode=sender.selectedSegment==0;go(1)
    }
    static func providerURL(_ input:String)->String?{
        let raw=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !raw.contains(where:{$0.isWhitespace}),let u=URLComponents(string:raw),
              ["http","https"].contains(u.scheme?.lowercased() ?? ""),let host=u.host,!host.isEmpty,
              u.fragment==nil, u.url != nil else{return nil}
        return raw
    }
    static func attachProvider(_ url:String,to cfg:inout [String:Any],exitNode:[String:Any],group:String){
        cfg["proxies"]=[exitNode]
        cfg["proxy-providers"]=["Team-Subscription":["type":"http","url":url,"interval":3600] as [String:Any]]
        cfg["proxy-groups"]=[["name":group,"type":"select","use":["Team-Subscription"]] as [String:Any]]
    }
    static func parseUpstream(_ input:String)->(String,String,Int,String,String)?{
        let raw=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !raw.contains(where:{$0.isWhitespace}),let u=URLComponents(string:raw),
              let scheme=u.scheme?.lowercased(),["http","https","socks5"].contains(scheme),
              u.percentEncodedQuery==nil,["","/"].contains(u.percentEncodedPath),
              var host=u.host,!host.isEmpty,let port=u.port,(1...65535).contains(port)
        else{return nil}
        if host.hasPrefix("[") && host.hasSuffix("]"){host=String(host.dropFirst().dropLast())}
        guard !host.contains(where:{$0.isWhitespace || "/@?#".contains($0)}) else{return nil}
        return (scheme,host,port,u.user ?? "",u.password ?? "")
    }
    @objc private func importUpstream(){
        guard let (scheme,host,port,user,pass)=Self.parseUpstream(value("upURI")) else{
            result.stringValue="请输入带端口的 HTTP、HTTPS 或 SOCKS5 单节点链接。订阅 URL 请切换到「订阅链接」。";return
        }
        proto.selectItem(withTitle:scheme.uppercased())
        for (key,v) in ["upHost":host,"upPort":String(port),"upUser":user,"upPass":pass,"upURI":""]{fields[key]?.stringValue=v}
        result.stringValue="已在本机解析节点链接，未发起连接。"
    }
    @objc private func skipPurchase(){go(1)}
    @objc private func editDelivery(){go(0)}
    private var deliveryValid:Bool {
        let host=value("ipHost").trimmingCharacters(in:.whitespacesAndNewlines)
        let ip=value("expected").trimmingCharacters(in:.whitespacesAndNewlines)
        var a=in_addr(),b=in6_addr()
        return !host.isEmpty && !host.contains(where:{$0.isWhitespace || "/@".contains($0)})
            && (try? port("ipPort")) != nil && value("ipUser").isEmpty == value("ipPass").isEmpty
            && (inet_pton(AF_INET,ip,&a)==1 || inet_pton(AF_INET6,ip,&b)==1)
    }
    @objc private func checkDelivery(){
        guard deliveryValid else{result.stringValue="请检查 IPRoyal 服务器、端口、预期出口 IP，以及成对填写的代理用户名和密码。";return}
        go(1);result.stringValue="已带入 IPRoyal 资料。这里只需补充上游参数。"
    }
    @objc private func openCloud(){openClient("Hubstudio",fallback:"https://www.hubstudio.cn/")}
    private func openClient(_ name:String,fallback:String){
        for base in ["/Applications",NSHomeDirectory()+"/Applications"]{let app=URL(fileURLWithPath:base).appendingPathComponent(name+".app");if FileManager.default.fileExists(atPath:app.path){NSWorkspace.shared.open(app);return}}
        NSWorkspace.shared.open(URL(string:fallback)!)
    }
    @objc private func openPictureGuide(){
        guard let url=Bundle.main.url(forResource:"morelogin-guide",withExtension:"html"),
              var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return}
        if let config=browserRoute(){parts.fragment="port="+String(config.port)}
        if let link=parts.url {NSWorkspace.shared.open(link)}
    }
    private func browserRoute()->(port:Int,ip:String)? {
        guard let bytes=try? Data(contentsOf:root.appendingPathComponent("ip-claude-monitor.json")),
              let cfg=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
              let expected=cfg["expected_ip"] as? String,!expected.isEmpty else{return nil}
        // Legacy personal monitor used a dedicated listener fixed at 1133.
        let endpoint=(cfg["probe_listener"] as? String) ?? "http://127.0.0.1:1133"
        guard let url=URLComponents(string:endpoint),url.scheme=="http",url.host=="127.0.0.1",
              let port=url.port,(1...65535).contains(port) else{return nil}
        return (port,expected)
    }
    @objc private func copyCheckURL(){
        guard let cfg=browserRoute(),let f=Bundle.main.url(forResource:"egress-test",withExtension:"html"),
              let template=try? String(contentsOf:f,encoding:.utf8) else{result.stringValue="请先完成固定出口设置。";return}
        var a=in_addr(),b=in6_addr()
        guard inet_pton(AF_INET,cfg.ip,&a)==1 || inet_pton(AF_INET6,cfg.ip,&b)==1 else{result.stringValue="预期出口 IP 无效。";return}
        let name=stage==3 ? "HubStudio 云真机" : "MoreLogin 浏览器"
        let page=template.replacingOccurrences(of:"__ENV__",with:name).replacingOccurrences(of:"__IP__",with:cfg.ip)
        let board=NSPasteboard.general;board.clearContents();board.setString("data:text/html;charset=utf-8;base64,"+Data(page.utf8).base64EncodedString(),forType:.string)
        result.stringValue="已复制检测页。请在"+name+"的地址栏粘贴并回车，结果会显示在该环境内。"
    }
    private var runningCheck=false
    @objc private func checkLocal(_ sender:NSButton){
        guard !runningCheck else{return}
        guard let script=Bundle.main.url(forResource:"verify_route_once",withExtension:"py",subdirectory:"monitor"),
              let py=["/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"].first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{result.stringValue="缺少检测程序或 Python。";return}
        let target=root.appendingPathComponent("ip-claude-monitor.json")
        let cfg=generated?.appendingPathComponent("monitor.json") ?? target
        guard FileManager.default.fileExists(atPath:cfg.path) else{result.stringValue="请先生成配置或启用监控。";return}
        runningCheck=true;result.stringValue="正在重新检测专用出口、分流规则和公网连通…";sender.isEnabled=false
        DispatchQueue.global(qos:.userInitiated).async {
            let t=Process(),pipe=Pipe();t.executableURL=URL(fileURLWithPath:py);t.arguments=["-B",script.path,cfg.path];t.standardOutput=pipe;t.standardError=FileHandle.nullDevice
            let msg:String
            do{try t.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();t.waitUntilExit();msg=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""}catch{msg=""}
            DispatchQueue.main.async{self.runningCheck=false;sender.isEnabled=true;if self.stage==1{self.result.stringValue=msg.isEmpty ? "未取得检测结果，请检查 Python 环境。" : msg}}
        }
    }
    @objc private func compareBrowserIP(){
        guard let cfg=browserRoute() else{return}
        let observed=value("browserIP").trimmingCharacters(in:.whitespacesAndNewlines)
        var a=in_addr(),b=in_addr(),a6=in6_addr(),b6=in6_addr()
        let match:Bool
        if inet_pton(AF_INET,observed,&a)==1 { match=inet_pton(AF_INET,cfg.ip,&b)==1 && a.s_addr==b.s_addr }
        else if inet_pton(AF_INET6,observed,&a6)==1 {match=inet_pton(AF_INET6,cfg.ip,&b6)==1 && memcmp(&a6,&b6,16)==0}
        else {result.stringValue="请粘贴检测页显示的纯 IP 地址。";return}
        result.stringValue=match ? "✓ 该环境提供的出口 IP 与预期一致。" : "出口不一致。请先检查该环境的代理类型、主机和端口，保存并重新启动环境。"
    }
    @objc private func openBrowser(){
        openClient("MoreLogin",fallback:"https://www.morelogin.com/zh/antidetect-browser")
    }
    @objc private func reveal(){if let generated{NSWorkspace.shared.activateFileViewerSelecting([generated.appendingPathComponent("Claude-IPRoyal.yaml")])}}
    @objc private func dashboard(){NotificationCenter.default.post(name:Notification.Name("OpenMonitor"),object:nil)}
    private func refreshHealth(){
        func read(_ f:String)->[String:Any]?{
            guard let data=try? Data(contentsOf:root.appendingPathComponent(f)) else{return nil}
            return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        }
        guard let expected=read("ip-claude-monitor.json")?["expected_ip"] as? String,!expected.isEmpty else{
            health.stringValue="尚未检测到固定出口配置。";return
        }
        guard let s=read("state.json") else{health.stringValue="等待监控后台产生第一轮结果。";return}
        health.stringValue=Self.assessment(s,expected:expected,now:Date().timeIntervalSince1970)
    }
    static func assessment(_ s:[String:Any],expected:String,now:Double)->String {
        guard let t=s["updated_at"] as? Double,(0...120).contains(now-t) else{return "暂无近期结果，等待后台下一轮检测。"}
        let names=["公网出口","Claude 分流策略","公网连通"]
        guard let rows=s["checks"] as? [[String:Any]],rows.map({$0["name"] as? String})==names,
              s["expected_ip"] as? String==expected else{return "配置已变化或结果不完整，等待重新检测。"}
        var issues=[String]()
        for (i,r) in rows.enumerated(){
            if r["status"] as? String != "ok"{issues.append(names[i]+"："+(r["detail"] as? String ?? "未通过"))}
            else if i==0 && r["ip"] as? String != expected {issues.append("公网出口与预期 IP 不一致")}
        }
        if let clash=s["clash"] as? [String:Any],clash["status"] as? String != "ok"{issues.append(clash["detail"] as? String ?? "Clash 状态异常")}
        if !issues.isEmpty{return "需要处理："+issues.joined(separator:"；")}
        guard s["status"] as? String=="ok", (s["clash"] as? [String:Any])?["status"] as? String=="ok" else{return "本机尚未通过："+(s["summary"] as? String ?? "请查看监控详情")}
        return "✓  本机已通过：固定出口 "+expected+"，Claude 分流和公网连通正常。"
    }
    func show(){
        // Keep current position when reopening the setup window.
        refreshHealth()
        if ticker==nil{ticker=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self] _ in
            guard let self,self.win.isVisible else{return};self.refreshHealth()
        }}
        win.center();win.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    private func title(_ s:String){let l=NSTextField(labelWithString:s);l.font = .boldSystemFont(ofSize:22);stack.addArrangedSubview(l)}
    private func note(_ s:String){let l=NSTextField(wrappingLabelWithString:s);stack.addArrangedSubview(l);l.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
    private func button(_ s:String,_ action:Selector){stack.addArrangedSubview(NSButton(title:s,target:self,action:action))}
    private func single(_ label:String,_ key:String,_ hint:String){
        let l=NSTextField(labelWithString:label);l.widthAnchor.constraint(equalToConstant:115).isActive=true
        let f=NSTextField();f.placeholderString=hint;fields[key]=f;f.widthAnchor.constraint(equalToConstant:240).isActive=true
        stack.addArrangedSubview(NSStackView(views:[l,f]))
    }
    private func row(_ label:String,_ k:String,_ h:String,_ k2:String,_ h2:String,_ secret:Bool=false){
        let l=NSTextField(labelWithString:label);l.widthAnchor.constraint(equalToConstant:115).isActive=true
        let a=NSTextField(),b:NSTextField=secret ? NSSecureTextField() : NSTextField();a.placeholderString=h;b.placeholderString=h2; fields[k]=a;fields[k2]=b
        let r=NSStackView(views:[l,a,b]);stack.addArrangedSubview(r);r.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;a.widthAnchor.constraint(equalTo:b.widthAnchor).isActive=true
    }
    @objc private func openClash(){
        let u=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"io.github.clash-verge-rev.clash-verge-rev") ?? URL(string:"https://github.com/clash-verge-rev/clash-verge-rev/releases/latest")!
        NSWorkspace.shared.open(u)
    }
    private func fail(_ s:String)->NSError{NSError(domain:"Setup",code:1,userInfo:[NSLocalizedDescriptionKey:s])}
    private func value(_ k:String)->String{fields[k]?.stringValue ?? draft[k] ?? ""}
    private func port(_ k:String)throws->Int{guard let n=Int(value(k)),(1...65535).contains(n) else{throw fail("请填写 1–65535 范围内的有效端口。")};return n}
    private func save(_ obj:Any,_ url:URL)throws{
        let bytes=try JSONSerialization.data(withJSONObject:obj,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        guard FileManager.default.createFile(atPath:url.path,contents:bytes,attributes:[.posixPermissions:0o600]) else{throw fail("无法保存本机配置。")}
    }
    func profile(_ a:[String:Any],_ b:[String:Any],_ p:Int)->[String:Any]{
        return ["mode":"rule","allow-lan":false,"proxies":[a,b],"listeners":[["name":"Claude-Residential","type":"http","listen":"127.0.0.1","port":p,"proxy":exit] as [String:Any]],"rules":domains.map{"DOMAIN-SUFFIX,"+$0+","+exit}+["MATCH,DIRECT"]]
    }
    @objc private func generate(){do{
        let fm=FileManager.default
        var addr=in_addr(),addr6=in6_addr();let ip=value("expected").trimmingCharacters(in:.whitespacesAndNewlines)
        guard inet_pton(AF_INET,ip,&addr)==1 || inet_pton(AF_INET6,ip,&addr6)==1 else{throw fail("请填写供应商给出的预期固定出口 IP。")}
        let p=try port("port");guard p>=1024 && ![7897,18765].contains(p) else{throw fail("请使用未占用的非系统端口，例如 1133。")}
        func node(_ prefix:String,_ name:String,_ kind:String)throws->[String:Any]{
            let host=value(prefix+"Host").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !host.isEmpty && !host.contains("/") && !host.contains("@") && !host.contains(where:{$0.isWhitespace}) else{throw fail("代理服务器只填写主机名或 IP，不包含协议、账号或路径。")}
            var d:[String:Any]=["name":name,"type":kind,"server":host,"port":try port(prefix+"Port")]
            for (key,field) in [("username","User"),("password","Pass")] where !value(prefix+field).isEmpty{ d[key]=value(prefix+field) };return d
        }
        var b=try node("ip",exit,"socks5");b["dialer-proxy"]=upstream
        var cfg:[String:Any]
        if subscriptionMode {
            guard let url=Self.providerURL(value("subscription")) else{throw fail("请粘贴完整的 HTTP(S) Clash 订阅地址，不是服务商登录页。")}
            cfg=profile([:],b,p);Self.attachProvider(url,to:&cfg,exitNode:b,group:upstream)
        } else {
            var a=try node("up",upstream,proto.indexOfSelectedItem==2 ? "socks5":"http")
            if proto.indexOfSelectedItem==1{a["tls"]=true};cfg=profile(a,b,p)
        }
        let dir=root.appendingPathComponent("Setup/"+UUID().uuidString)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=dir.appendingPathComponent("Claude-IPRoyal.yaml")
        try save(cfg,file);try save(["expected_ip":ip,"expected_proxy":exit,"upstream":upstream,"groups":[],"auto_fix":false,"probe_listener":"http://127.0.0.1:"+String(p)] as [String:Any],dir.appendingPathComponent("monitor.json"))
        generated=dir;UserDefaults.standard.set(dir.lastPathComponent,forKey:"teamFlowGenerated")
        result.stringValue=subscriptionMode ? "已生成。导入 Clash → 在 Team-Upstream 组选择订阅节点 → 检测实际出口。" : "配置已生成。在 Clash 中导入并选用后，点击「启用监控」。";NSWorkspace.shared.activateFileViewerSelecting([file])
    }catch{result.stringValue=error.localizedDescription}}
    @objc private func enable(){
        do{
            let fm=FileManager.default,target=root.appendingPathComponent("ip-claude-monitor.json"),marker=root.appendingPathComponent(".team-install")
            if fm.fileExists(atPath:target.path) && !fm.fileExists(atPath:marker.path){
                result.stringValue="本机已有个人监控，已保留原配置。请核对面板的预期 IP 是否与本次配置一致。"
                NotificationCenter.default.post(name:Notification.Name("OpenMonitor"),object:nil);return
            }
            if generated == nil && fm.fileExists(atPath:target.path){dashboard();return}
            guard let dir=generated else{throw fail("请先生成并导入本次配置。")}
            let python=try ["/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"].first{path in
                guard fm.isExecutableFile(atPath:path) else{return false}
                let t=Process();t.executableURL=URL(fileURLWithPath:path);t.arguments=["-c","import sys;sys.exit(sys.version_info<(3,9))"];t.standardError=FileHandle.nullDevice;try t.run();t.waitUntilExit();return t.terminationStatus==0
            };guard let python else{throw fail("需要 Python 3.9 或更新版本，请安装后重试。")}
            guard let src=Bundle.main.resourceURL?.appendingPathComponent("monitor"),fm.fileExists(atPath:src.appendingPathComponent("dashboard.html").path) else{throw fail("应用缺少团队监控资源。")}
            let label="com.codex.ip-claude-monitor",agents=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            let plist=agents.appendingPathComponent(label+".plist")
            guard fm.fileExists(atPath:marker.path) || (!fm.fileExists(atPath:plist.path) && !fm.fileExists(atPath:root.appendingPathComponent("ip_claude_monitor.py").path)) else{throw fail("发现已有监控服务，未覆盖。")}
            let backup=dir.appendingPathComponent("previous");try fm.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let names:[String]=["ip_claude_monitor.py","ip_claude_check.py","monitor_dashboard.py","dashboard.html"]
            for f in [plist,target]+names.map({root.appendingPathComponent($0)}) where fm.fileExists(atPath:f.path){try fm.copyItem(at:f,to:backup.appendingPathComponent(f.lastPathComponent))}
            for name in names{try Data(contentsOf:src.appendingPathComponent(name)).write(to:root.appendingPathComponent(name),options:.atomic)}
            try Data(contentsOf:dir.appendingPathComponent("monitor.json")).write(to:target,options:.atomic)
            try Data().write(to:marker)
            try fm.createDirectory(at:agents,withIntermediateDirectories:true)
            let spec:[String:Any]=["Label":label,"ProgramArguments":[python,root.appendingPathComponent(names[0]).path],"RunAtLoad":true,"KeepAlive":true,"StandardErrorPath":root.appendingPathComponent("service.log").path]
            try PropertyListSerialization.data(fromPropertyList:spec,format:.xml,options:0).write(to:plist,options:.atomic)
            let gui="gui/"+String(getuid())
            func ctl(_ args:[String])throws->Int32{let t=Process();t.executableURL=URL(fileURLWithPath:"/bin/launchctl");t.arguments=args;try t.run();t.waitUntilExit();return t.terminationStatus}
            _=try ctl(["bootout",gui+"/"+label]);guard try ctl(["bootstrap",gui,plist.path])==0 else{throw fail("后台启动失败，请检查登录项权限。旧文件备份在本次配置目录的 previous 中。")}
            refreshHealth();result.stringValue="后台已启动。验收结果会自动刷新。"
        }catch{result.stringValue=error.localizedDescription}
    }
}
