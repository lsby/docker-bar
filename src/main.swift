import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var startMenuItem: NSMenuItem!
    var stopMenuItem: NSMenuItem!
    var restartMenuItem: NSMenuItem!
    var terminalMenuItem: NSMenuItem!
    var logsMenuItem: NSMenuItem!
    var quitMenuItem: NSMenuItem!
    var timer: Timer?
    var isBusy: Bool = false
    var watchdogPipe: Pipe?
    var watchdogProcess: Process?

    // 动态检索 colima 与 docker 路径
    lazy var colimaPath: String = {
        let candidates = [
            NSHomeDirectory() + "/.homebrew/bin/colima",
            "/opt/homebrew/bin/colima",
            "/usr/local/bin/colima",
            "/usr/bin/colima"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return "colima"
    }()

    lazy var dockerSock: String = {
        let primary = NSHomeDirectory() + "/.colima/default/docker.sock"
        let fallback = NSHomeDirectory() + "/.colima/docker.sock"
        if FileManager.default.fileExists(atPath: primary) {
            return primary
        }
        return fallback
    }()

    lazy var logPath: String = {
        return NSHomeDirectory() + "/.colima/_lima/colima/ha.stderr.log"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动内核管道看门狗子进程（强进程生命周期绑定）
        startWatchdog()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusDisplay(status: "starting")

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Docker 状态: 正在检测...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        startMenuItem = NSMenuItem(title: "启动 Docker (Start)", action: #selector(startDocker), keyEquivalent: "s")
        startMenuItem.target = self
        menu.addItem(startMenuItem)

        stopMenuItem = NSMenuItem(title: "停止 Docker (Stop)", action: #selector(stopDocker), keyEquivalent: "t")
        stopMenuItem.target = self
        menu.addItem(stopMenuItem)

        restartMenuItem = NSMenuItem(title: "重启 Docker (Restart)", action: #selector(restartDocker), keyEquivalent: "r")
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)

        menu.addItem(NSMenuItem.separator())

        terminalMenuItem = NSMenuItem(title: "打开终端命令行 (Terminal)", action: #selector(openTerminal), keyEquivalent: "o")
        terminalMenuItem.target = self
        menu.addItem(terminalMenuItem)

        logsMenuItem = NSMenuItem(title: "查看实时日志 (Logs)", action: #selector(openLogs), keyEquivalent: "l")
        logsMenuItem.target = self
        menu.addItem(logsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let aboutMenuItem = NSMenuItem(title: "关于 DockerBar (About)", action: #selector(showAbout), keyEquivalent: "a")
        aboutMenuItem.target = self
        menu.addItem(aboutMenuItem)

        quitMenuItem = NSMenuItem(title: "退出并停止 Docker (Quit)", action: #selector(quitApp), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu

        // 启动时自动检查，若未运行则自动拉起 Docker
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: dockerSock) {
            startDocker()
        } else {
            checkStatus()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }

        // 注册 POSIX 退出信号
        signal(SIGINT) { _ in AppDelegate.handleSignalExit() }
        signal(SIGTERM) { _ in AppDelegate.handleSignalExit() }
    }

    static func handleSignalExit() {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "colima stop 2>/dev/null"]
        try? task.run()
        task.waitUntilExit()
        exit(0)
    }

    func startWatchdog() {
        let pipe = Pipe()
        self.watchdogPipe = pipe

        let process = Process()
        process.launchPath = "/bin/sh"
        let script = """
        cat > /dev/null
        # 管道被操作系统内核关闭（主程序正常退出、闪退或被强杀）
        HA_PID=$(cat "$HOME/.colima/_lima/colima/ha.pid" 2>/dev/null)
        VZ_PID=$(cat "$HOME/.colima/_lima/colima/vz.pid" 2>/dev/null)
        [ -n "$HA_PID" ] && kill -TERM "$HA_PID" 2>/dev/null
        [ -n "$VZ_PID" ] && kill -TERM "$VZ_PID" 2>/dev/null
        colima stop 2>/dev/null || \(colimaPath) stop 2>/dev/null
        sleep 2
        [ -n "$HA_PID" ] && kill -9 "$HA_PID" 2>/dev/null
        [ -n "$VZ_PID" ] && kill -9 "$VZ_PID" 2>/dev/null
        """
        process.arguments = ["-c", script]
        process.standardInput = pipe
        try? process.run()
        self.watchdogProcess = process
    }

    func applicationWillTerminate(_ notification: Notification) {
        reclaimDockerProcesses()
    }

    func reclaimDockerProcesses() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dockerSock) {
            let task = Process()
            task.launchPath = colimaPath
            task.arguments = ["stop"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
        }
    }

    func updateStatusDisplay(status: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                switch status {
                case "running":
                    button.title = "🐳 🟢"
                    self.statusMenuItem.title = "Docker 状态: 🟢 运行中"
                    self.startMenuItem.isEnabled = false
                    self.stopMenuItem.isEnabled = true
                    self.restartMenuItem.isEnabled = true
                    self.quitMenuItem.title = "退出并停止 Docker (Quit)"
                case "stopped":
                    button.title = "🐳 ⚪️"
                    self.statusMenuItem.title = "Docker 状态: ⚪️ 已停止 (0占用)"
                    self.startMenuItem.isEnabled = true
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.quitMenuItem.title = "退出托盘 (Quit)"
                case "starting":
                    button.title = "🐳 🟡"
                    self.statusMenuItem.title = "Docker 状态: 🟡 正在启动..."
                    self.startMenuItem.isEnabled = false
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.quitMenuItem.title = "退出托盘 (Quit)"
                case "stopping":
                    button.title = "🐳 🟡"
                    self.statusMenuItem.title = "Docker 状态: 🟡 正在停止并回收资源..."
                    self.startMenuItem.isEnabled = false
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.quitMenuItem.title = "正在退出..."
                default:
                    button.title = "🐳 ⚪️"
                    self.statusMenuItem.title = "Docker 状态: ⚪️ 检查中"
                }
            }
        }
    }

    func checkStatus() {
        if isBusy { return }
        DispatchQueue.global(qos: .background).async {
            let fileManager = FileManager.default
            let isRunning = fileManager.fileExists(atPath: self.dockerSock)
            if isRunning {
                self.updateStatusDisplay(status: "running")
            } else {
                self.updateStatusDisplay(status: "stopped")
            }
        }
    }

    @objc func startDocker() {
        if isBusy { return }
        isBusy = true
        updateStatusDisplay(status: "starting")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = self.colimaPath
            task.arguments = ["start"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
            self.isBusy = false
            self.checkStatus()
        }
    }

    @objc func stopDocker() {
        if isBusy { return }
        isBusy = true
        updateStatusDisplay(status: "stopping")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = self.colimaPath
            task.arguments = ["stop"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
            self.isBusy = false
            self.checkStatus()
        }
    }

    @objc func restartDocker() {
        if isBusy { return }
        isBusy = true
        updateStatusDisplay(status: "starting")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = self.colimaPath
            task.arguments = ["restart"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {}
            self.isBusy = false
            self.checkStatus()
        }
    }

    @objc func openTerminal() {
        let script = "tell application \"Terminal\" to do script \"docker ps\""
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    @objc func openLogs() {
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            let alert = NSAlert()
            alert.messageText = "日志文件尚未生成"
            alert.informativeText = "路径: \(logPath)"
            alert.runModal()
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DockerBar v1.0.0"
        alert.informativeText = "极轻量、原生的 macOS 状态栏 Docker 容器生命周期管理工具。\n\n特点：\n• 进程强生命周期绑定（退出即彻底释放资源）\n• 内核管道看门狗防孤儿进程\n• 极低内存常驻 (~15MB)\n\n开源协议: MIT License"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc func quitApp() {
        isBusy = true
        updateStatusDisplay(status: "stopping")
        DispatchQueue.global(qos: .userInitiated).async {
            self.reclaimDockerProcesses()
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
