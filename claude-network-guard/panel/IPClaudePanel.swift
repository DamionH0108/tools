import AppKit
import WebKit

final class MovableBadge: NSButton {
    var onDrop: (() -> Void)?
    private var anchor: NSPoint?
    private var start = NSPoint.zero
    private var dragged = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        anchor = NSEvent.mouseLocation
        start = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        guard dragged || dx*dx + dy*dy >= 16 else { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: start.x+dx, y: start.y+dy))
    }
    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        anchor = nil
        if dragged { onDrop?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)), let action {
            _ = sendAction(action, to: target)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private lazy var wizard = SetupWizard()
    @objc private func openSetup(){wizard.show()}
    private let dashboardURL = URL(string: "http://127.0.0.1:18765/")!
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var summaryItem = NSMenuItem()
    private var panel: NSWindow?
    private var timer: Timer?
    private var lastState = "checking"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showBadge()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "IP …"
        statusItem.button?.toolTip = "IP / Claude 监控"

        summaryItem.title = "正在连接监控后台…"
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开监控面板", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "从零搭建…", action:#selector(openSetup), keyEquivalent:"")
        menu.addItem(withTitle: "刷新状态", action: #selector(refresh), keyEquivalent: "r")
        menu.items.forEach { if $0.action != nil { $0.target = self } }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 IP / Claude 监控", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu

        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        refresh()
        NotificationCenter.default.addObserver(self, selector:#selector(openPanel), name:Notification.Name("OpenMonitor"), object:nil)
        if CommandLine.arguments.contains("--setup") || !FileManager.default.fileExists(atPath:NSHomeDirectory()+"/Library/Application Support/ip-claude-monitor/ip-claude-monitor.json"){openSetup()}
        NotificationCenter.default.addObserver(self, selector: #selector(placeBadge), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var badge: NSPanel?
    private let badgeButton = MovableBadge()
    private func showBadge() {
        let box = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 184, height: 62),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        box.title = "IP 网络评分"
        box.level = .floating
        box.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        box.hidesOnDeactivate = false
        box.isOpaque = false
        box.backgroundColor = .clear
        box.hasShadow = true
        badgeButton.frame = NSRect(origin: .zero, size: box.frame.size)
        badgeButton.isBordered = false
        badgeButton.wantsLayer = true
        badgeButton.layer?.cornerRadius = 14
        badgeButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        badgeButton.title = "正在读取评分…"
        badgeButton.target = self
        badgeButton.action = #selector(openPanel)
        box.contentView = badgeButton
        badge = box
        badgeButton.onDrop = { [weak self, weak box] in
            guard let box else { return }
            UserDefaults.standard.set(NSStringFromPoint(box.frame.origin), forKey: "badgeOrigin")
            self?.placeBadge()
        }
        placeBadge()
        box.orderFrontRegardless()
    }
    @objc private func placeBadge() {
        guard let box = badge, let screen = NSScreen.screens.first else { return }
        if let value = UserDefaults.standard.string(forKey: "badgeOrigin") {
            let p = NSPointFromString(value), size = box.frame.size
            let rect = NSRect(origin: p, size: size)
            func overlap(_ s: NSScreen) -> CGFloat {
                let r = rect.intersection(s.visibleFrame)
                return r.isNull ? 0 : r.width*r.height
            }
            let best = NSScreen.screens.max { overlap($0) < overlap($1) }
            let area = ((best.flatMap { overlap($0) > 0 ? $0 : nil }) ?? screen).visibleFrame
            box.setFrameOrigin(NSPoint(x: max(area.minX, min(p.x, area.maxX-size.width)),
                                       y: max(area.minY, min(p.y, area.maxY-size.height))))
            return
        }
        box.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - box.frame.width - 12,
                                         y: screen.visibleFrame.maxY - 10))
    }
    private func grade(_ d: [String:Any]) -> Int? {
        guard let updated = d["updated_at"] as? Double,
              Date().timeIntervalSince1970-updated <= max(120, 2*(d["interval"] as? Double ?? 60)),
              let expected = d["expected_ip"] as? String,
              let rows = d["checks"] as? [[String:Any]], rows.count == 3 else { return nil }
        let ipPoints = rows[0]["ip"] as? String == expected && rows[0]["status"] as? String == "ok" ? 35 : 0
        let guardPoints = rows[1]["status"] as? String == "ok" ? 35 : 0
        let clashOK = (d["clash"] as? [String:Any])?["status"] as? String == "ok"
        let netOK = rows[2]["status"] as? String == "ok"
        let total = ipPoints + guardPoints + (clashOK ? 15 : 0) + (netOK ? 15 : 0)
        return (!clashOK || !netOK) ? min(84,total) : total
    }

    @objc private func refresh() {
        var request = URLRequest(url: dashboardURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var state = "error"
            var summary = "监控后台不可用"
            var ip = "—"
            var score: Int?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                score = self.grade(json)
                state = json["status"] as? String ?? "warning"
                summary = json["summary"] as? String ?? "检测中"
                if let checks = json["checks"] as? [[String: Any]], let first = checks.first,
                   let value = first["ip"] as? String { ip = value }
            }
            DispatchQueue.main.async {
                let line = score.map { String($0) + " 分 · " + ($0 >= 85 ? "合格" : "需检查") } ?? "暂无有效评分"
                let text = NSMutableAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: (score ?? 0) >= 85 ? NSColor.systemMint : NSColor.systemOrange])
                text.append(NSAttributedString(string: "\n"+ip, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white]))
                self.badgeButton.attributedTitle = text
                self.badgeButton.toolTip = "≥85 分合格 · 拖动可移动 · 单击打开详情"
                self.lastState = state
                let icon = state == "ok" ? "✓" : (state == "warning" ? "!" : "×")
                self.statusItem.button?.title = "IP \(icon)"
                self.statusItem.button?.contentTintColor = state == "ok" ? .systemGreen : (state == "warning" ? .systemOrange : .systemRed)
                let statusText = state == "ok" ? "正常" : (state == "warning" ? "需确认" : "异常")
                self.summaryItem.title = "\(statusText) · \(ip)"
                self.summaryItem.toolTip = summary
            }
        }.resume()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openPanel()
        return true
    }

    @objc private func openPanel() {
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.title = "IP / Claude 监控"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let web = WKWebView(frame: .zero)
            web.autoresizingMask = [.width, .height]
            let bar=NSStackView(views:[NSButton(title:"从零搭建…",target:self,action:#selector(openSetup))]);bar.edgeInsets=NSEdgeInsets(top:6,left:12,bottom:6,right:12)
            let body=NSStackView(views:[bar,web]);body.orientation = .vertical;body.alignment = .leading;body.spacing=0;window.contentView=body
            web.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true
            panel = window
            web.load(URLRequest(url: dashboardURL))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.deminiaturize(nil)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main enum PanelMain { static func main(){
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

withExtendedLifetime(delegate) {}
} }
