#!/usr/bin/env bash
set -e

echo "🐳 正在检查并安装 DockerBar 运行依赖 (Colima + Docker)..."

if ! command -v brew &>/dev/null; then
    echo "❌ 未检测到 Homebrew，请先安装 Homebrew: https://brew.sh"
    exit 1
fi

echo "📦 安装 colima 与 docker CLI..."
brew install colima docker

echo "✅ 依赖安装完成！您可以直接打开 DockerBar 体验容器服务。"
