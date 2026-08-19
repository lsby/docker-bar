# DockerBar 🐳

> 极轻量、原生的 macOS 状态栏 Docker 容器生命周期管理工具。
> 像 Docker Desktop 一样拥有可视化托盘控制，但拥有极致的资源控制与 **强父子进程硬回收** 机制。

---

## 🌟 核心特性 (Features)

- 🪶 **极致轻量**：原生 Swift / Cocoa 编写，菜单栏常驻内存仅 **~15MB**，空闲时 CPU 占用 **0%**。
- 🔄 **强进程生命周期绑定（Process-Bound Lifecycle）**：
  - **打开即启动**：打开应用自动拉起 Docker 守护进程。
  - **退出即回收**：退出托盘应用自动安全关闭 Docker 虚拟机并彻底释放 100% 内存与 CPU。
- 🛡️ **内核管道看门狗（Kernel Pipe Watchdog）**：
  - 即使托盘应用遭遇崩溃、闪退或被 `kill -9` 强杀，macOS 内核管道关闭事件将触发看门狗瞬间终止所有虚拟机孤儿进程，**绝不残留无主后台进程**。
- 📊 **状态直观可视**：
  - `🐳 🟢`：Docker 运行中
  - `🐳 ⚪️`：Docker 已停止（0 资源占用）
  - `🐳 🟡`：正在启动 / 正在停止中
- ⚡️ **全版本支持**：特别优化对老款 Mac（macOS 13 Ventura / Intel 处理器 / 8GB 内存无风扇 MacBook 等）的运行支持。

---

## 🆚 与其他方案对比

| 对比维度 | Docker Desktop | OrbStack | **DockerBar** |
| :--- | :--- | :--- | :--- |
| **内存开销 (空闲)** | 2.5 GB ~ 4.0 GB | ~200 MB | **~15 MB (托盘) + 0 MB (关闭后)** |
| **macOS 13 (Ventura) 支持** | ❌ 新版已放弃 | ❌ 新版已放弃 (需 macOS 14+) | ✅ **完美支持** |
| **生命周期硬绑定** | ❌ 退出界面后台常驻 | ❌ 退出界面后台常驻 | ✅ **退出即 100% 释放系统资源** |
| **防孤儿进程泄漏** | ⚠️ 依赖守护进程 | ⚠️ 依赖守护进程 | ✅ **内核级管道看门狗硬回收** |
| **开源与透明** | 闭源商业化限制 | 闭源收费 | ✅ **100% MIT 开源免费** |

---

## 🚀 快速开始

### 1. 安装底层运行时依赖
DockerBar 基于 Colima 和 Docker CLI 驱动：
```bash
brew install colima docker
```

### 2. 下载或构建 DockerBar
您可以直接在 [Releases](../../releases) 下载预编译产物，或通过一行命令本地编译：
```bash
git clone https://github.com/lsby/docker-bar.git
cd docker-bar
./scripts/build.sh
```

编译完成后将 `dist/DockerBar.app` 移动到 `~/Applications/` 或 `/Applications/` 即可。

---

## 🛠️ 常用菜单操作

- **启动 Docker (Start)**：拉起后台虚拟机并连接 Docker 客户端。
- **停止 Docker (Stop)**：彻底停止虚拟机，将 CPU 与内存全额归还系统。
- **重启 Docker (Restart)**：快速重启容器运行时。
- **打开终端 (Terminal)**：一键打开 macOS 终端并进入 Docker CLI 环境。
- **查看实时日志 (Logs)**：快速查看虚拟机与容器守护进程日志。
- **退出并停止 Docker (Quit)**：退出托盘并全自动回收所有子进程。

---

## 📄 开源许可

本项目采用 [MIT License](LICENSE) 开源协议。
