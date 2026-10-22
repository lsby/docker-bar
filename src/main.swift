import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var startMenuItem: NSMenuItem!
    var stopMenuItem: NSMenuItem!
    var restartMenuItem: NSMenuItem!
    var toggleContainersMenuItem: NSMenuItem!
    var terminalMenuItem: NSMenuItem!
    var logsMenuItem: NSMenuItem!
    var quitMenuItem: NSMenuItem!
    var timer: Timer?
    var isBusy: Bool = false
    var watchdogPipe: Pipe?
    var watchdogProcess: Process?

    // 记录由 DockerBar 主动挂起的容器 ID，确保恢复时只恢复这批容器
    var pausedByDockerBarIds: Set<String> = []

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

    lazy var dockerPath: String = {
        let candidates = [
            NSHomeDirectory() + "/.homebrew/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return "docker"
    }()

    // 每次实时检测（首次启动前 socket 尚不存在，不能缓存）
    var dockerSock: String {
        let primary = NSHomeDirectory() + "/.colima/default/docker.sock"
        let fallback = NSHomeDirectory() + "/.colima/docker.sock"
        if FileManager.default.fileExists(atPath: primary) {
            return primary
        }
        return fallback
    }

    // 清理上次异常退出残留的 SSH 复用连接、网络进程和 socket，否则下次 colima start 会卡死
    static let cleanupScript = """
    if ! colima status >/dev/null 2>&1; then
        L="$HOME/.colima/_lima"
        pkill -f "ssh: $L/colima/ssh.sock" 2>/dev/null
        pkill -f "limactl hostagent .*$L/colima/" 2>/dev/null
        pkill -f "limactl usernet .*$L/_networks/" 2>/dev/null
        rm -f "$L/colima/ssh.sock" "$L/colima/ha.sock" "$L/colima/ha.pid" "$L/colima/vz.pid"
        rm -f "$L"/_networks/*/*.pid "$L"/_networks/*/*.sock
    fi
    """

    func runCleanup() {
        let task = Process()
       task.environment = AppDelegate.toolEnvironment
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", AppDelegate.cleanupScript]
        try? task.run()
        task.waitUntilExit()
    }

    // GUI 应用继承的 PATH 不含 Homebrew，colima 需要找到 limactl / docker
    static let toolEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.homebrew/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
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
        menu.delegate = self
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

        toggleContainersMenuItem = NSMenuItem(title: "暂停所有容器 (Pause All)", action: #selector(toggleContainersPauseState), keyEquivalent: "p")
        toggleContainersMenuItem.target = self
        toggleContainersMenuItem.isEnabled = false
        menu.addItem(toggleContainersMenuItem)

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
       task.environment = AppDelegate.toolEnvironment
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
       process.environment = AppDelegate.toolEnvironment
        process.launchPath = "/bin/sh"
        let script = """
        cat > /dev/null
        # 管道被操作系统内核关闭（主程序正常退出、闪退或被强杀）
        # 先让 colima 正常关闭；20 秒内没关掉再强杀，避免留下孤儿进程
        HA_PID=$(cat "$HOME/.colima/_lima/colima/ha.pid" 2>/dev/null)
        VZ_PID=$(cat "$HOME/.colima/_lima/colima/vz.pid" 2>/dev/null)
        colima stop 2>/dev/null &
        STOP_PID=$!
        for i in $(seq 1 20); do kill -0 "$STOP_PID" 2>/dev/null || break; sleep 1; done
        if kill -0 "$STOP_PID" 2>/dev/null; then
            kill "$STOP_PID" 2>/dev/null
            [ -n "$HA_PID" ] && kill -TERM "$HA_PID" 2>/dev/null
            [ -n "$VZ_PID" ] && kill -TERM "$VZ_PID" 2>/dev/null
            sleep 2
            [ -n "$HA_PID" ] && kill -9 "$HA_PID" 2>/dev/null
            [ -n "$VZ_PID" ] && kill -9 "$VZ_PID" 2>/dev/null
        fi
        \(AppDelegate.cleanupScript)
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
        self.pausedByDockerBarIds.removeAll()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dockerSock) {
            let task = Process()
           task.environment = AppDelegate.toolEnvironment
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
                    if !self.pausedByDockerBarIds.isEmpty {
                        self.toggleContainersMenuItem.title = "恢复暂停的容器 (Resume) [\(self.pausedByDockerBarIds.count)]"
                        self.toggleContainersMenuItem.isEnabled = true
                    } else {
                        self.toggleContainersMenuItem.title = "暂停所有容器 (Pause All)"
                        self.toggleContainersMenuItem.isEnabled = true
                    }
                    self.quitMenuItem.title = "退出并停止 Docker (Quit)"
                case "stopped":
                    button.title = "🐳 ⚪️"
                    self.statusMenuItem.title = "Docker 状态: ⚪️ 已停止 (0占用)"
                    self.startMenuItem.isEnabled = true
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.pausedByDockerBarIds.removeAll()
                    self.toggleContainersMenuItem.title = "暂停所有容器 (Pause All)"
                    self.toggleContainersMenuItem.isEnabled = false
                    self.quitMenuItem.title = "退出托盘 (Quit)"
                case "starting":
                    button.title = "🐳 🟡"
                    self.statusMenuItem.title = "Docker 状态: 🟡 正在启动..."
                    self.startMenuItem.isEnabled = false
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.pausedByDockerBarIds.removeAll()
                    self.toggleContainersMenuItem.title = "暂停所有容器 (Pause All)"
                    self.toggleContainersMenuItem.isEnabled = false
                    self.quitMenuItem.title = "退出托盘 (Quit)"
                case "stopping":
                    button.title = "🐳 🟡"
                    self.statusMenuItem.title = "Docker 状态: 🟡 正在停止并回收资源..."
                    self.startMenuItem.isEnabled = false
                    self.stopMenuItem.isEnabled = false
                    self.restartMenuItem.isEnabled = false
                    self.pausedByDockerBarIds.removeAll()
                    self.toggleContainersMenuItem.title = "暂停所有容器 (Pause All)"
                    self.toggleContainersMenuItem.isEnabled = false
                    self.quitMenuItem.title = "正在退出..."
                default:
                    button.title = "🐳 ⚪️"
                    self.statusMenuItem.title = "Docker 状态: ⚪️ 检查中"
                    self.toggleContainersMenuItem.isEnabled = false
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
            self.runCleanup()
            let task = Process()
           task.environment = AppDelegate.toolEnvironment
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
           task.environment = AppDelegate.toolEnvironment
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
            self.runCleanup()
            let task = Process()
           task.environment = AppDelegate.toolEnvironment
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

    // MARK: - 容器级别智能挂起与专属恢复 (Toggle Pause / Resume)

    func menuWillOpen(_ menu: NSMenu) {
        if FileManager.default.fileExists(atPath: self.dockerSock) && !isBusy {
            refreshContainersCount()
        }
    }

    func refreshContainersCount() {
        guard FileManager.default.fileExists(atPath: self.dockerSock) else {
            DispatchQueue.main.async {
                self.pausedByDockerBarIds.removeAll()
                self.toggleContainersMenuItem?.title = "暂停所有容器 (Pause All)"
                self.toggleContainersMenuItem?.isEnabled = false
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            export DOCKER_HOST="unix://\(self.dockerSock)"
            RUNNING=$(\(self.dockerPath) ps -q --filter "status=running" 2>/dev/null | grep -c . || true)
            PAUSED_IDS=$(\(self.dockerPath) ps -q --filter "status=paused" 2>/dev/null)
            echo "---SEP---"
            echo "$RUNNING"
            echo "---SEP---"
            echo "$PAUSED_IDS"
            """
            let task = Process()
            task.environment = AppDelegate.toolEnvironment
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let parts = output.components(separatedBy: "---SEP---")
                    if parts.count >= 3 {
                        let runningCount = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                        let pausedList = parts[2].components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let currentPausedSet = Set(pausedList)

                        DispatchQueue.main.async {
                            if !self.pausedByDockerBarIds.isEmpty {
                                // 已经处于由 DockerBar 暂停的状态，校验哪些容器仍然处于 paused 状态
                                let validPaused = self.pausedByDockerBarIds.intersection(currentPausedSet)
                                if validPaused.isEmpty {
                                    // 之前暂停的容器已经被外部恢复或停止了，自动回到初始状态
                                    self.pausedByDockerBarIds.removeAll()
                                    self.toggleContainersMenuItem?.title = "暂停所有容器 (Pause All) [\(runningCount)]"
                                    self.toggleContainersMenuItem?.isEnabled = (runningCount > 0)
                                } else {
                                    self.pausedByDockerBarIds = validPaused
                                    self.toggleContainersMenuItem?.title = "恢复暂停的容器 (Resume) [\(validPaused.count)]"
                                    self.toggleContainersMenuItem?.isEnabled = true
                                }
                            } else {
                                // 当前处于未暂停状态
                                self.toggleContainersMenuItem?.title = "暂停所有容器 (Pause All) [\(runningCount)]"
                                self.toggleContainersMenuItem?.isEnabled = (runningCount > 0)
                            }
                        }
                    }
                }
            } catch {
                NSLog("[DockerBar] 检测容器状态失败: \(error)")
            }
        }
    }

    @objc func toggleContainersPauseState() {
        if isBusy { return }
        if !pausedByDockerBarIds.isEmpty {
            resumePreviouslyPausedContainers()
        } else {
            pauseAllRunningContainers()
        }
    }

    func pauseAllRunningContainers() {
        NSLog("[DockerBar] 触发一键挂起所有运行中容器...")
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            export DOCKER_HOST="unix://\(self.dockerSock)"
            \(self.dockerPath) ps -q --filter "status=running" 2>/dev/null
            """
            let task = Process()
            task.environment = AppDelegate.toolEnvironment
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let ids = output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if !ids.isEmpty {
                    let pauseScript = """
                    export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
                    export DOCKER_HOST="unix://\(self.dockerSock)"
                    echo "\(ids.joined(separator: " "))" | xargs \(self.dockerPath) pause 2>/dev/null
                    """
                    let pauseTask = Process()
                    pauseTask.environment = AppDelegate.toolEnvironment
                    pauseTask.launchPath = "/bin/sh"
                    pauseTask.arguments = ["-c", pauseScript]
                    try pauseTask.run()
                    pauseTask.waitUntilExit()

                    DispatchQueue.main.async {
                        self.pausedByDockerBarIds = Set(ids)
                        self.toggleContainersMenuItem?.title = "恢复暂停的容器 (Resume) [\(ids.count)]"
                        self.toggleContainersMenuItem?.isEnabled = true
                        NSLog("[DockerBar] 成功挂起 \(ids.count) 个容器，已记录专属恢复 ID: \(self.pausedByDockerBarIds)")
                    }
                }
            } catch {
                NSLog("[DockerBar] 执行暂停容器出错: \(error)")
            }
            self.refreshContainersCount()
        }
    }

    func resumePreviouslyPausedContainers() {
        let targets = self.pausedByDockerBarIds
        NSLog("[DockerBar] 准备恢复由 DockerBar 暂停的容器，记录目标: \(targets)")
        DispatchQueue.global(qos: .userInitiated).async {
            // 先获取当前确实还处于 paused 状态的容器，取交集，确保绝不误恢复其它容器
            let script = """
            export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            export DOCKER_HOST="unix://\(self.dockerSock)"
            \(self.dockerPath) ps -q --filter "status=paused" 2>/dev/null
            """
            let task = Process()
            task.environment = AppDelegate.toolEnvironment
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let currentPaused = Set(output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })

                let toResume = targets.intersection(currentPaused)
                if !toResume.isEmpty {
                    let unpauseScript = """
                    export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
                    export DOCKER_HOST="unix://\(self.dockerSock)"
                    echo "\(Array(toResume).joined(separator: " "))" | xargs \(self.dockerPath) unpause 2>/dev/null
                    """
                    let unpauseTask = Process()
                    unpauseTask.environment = AppDelegate.toolEnvironment
                    unpauseTask.launchPath = "/bin/sh"
                    unpauseTask.arguments = ["-c", unpauseScript]
                    try unpauseTask.run()
                    unpauseTask.waitUntilExit()
                    NSLog("[DockerBar] 成功恢复专属容器: \(toResume)")
                }
            } catch {
                NSLog("[DockerBar] 执行恢复容器出错: \(error)")
            }

            DispatchQueue.main.async {
                self.pausedByDockerBarIds.removeAll()
                self.toggleContainersMenuItem?.title = "暂停所有容器 (Pause All)"
            }
            self.refreshContainersCount()
        }
    }

    @objc func openTerminal() {
        let task = Process()
       task.environment = AppDelegate.toolEnvironment
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"docker ps\""
        ]
        try? task.run()
    }

    @objc func openLogs() {
        let task = Process()
       task.environment = AppDelegate.toolEnvironment
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"tail -n 50 -f " + logPath + "\""
        ]
        try? task.run()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DockerBar v1.0.0"
        alert.informativeText = "极轻量、原生的 macOS 状态栏 Docker 容器生命周期管理工具。\n\n特点：\n• 进程强生命周期绑定（退出即彻底释放资源）\n• 内核管道看门狗防孤儿进程\n• 一键冻结与秒级唤醒容器 (Pause / Resume)\n• 极低内存常驻 (~15MB)\n\n开源协议: MIT License"
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
