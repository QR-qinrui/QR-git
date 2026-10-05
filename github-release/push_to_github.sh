#!/bin/bash
# 推送 ai-github-scanner skill 到 GitHub 仓库
#
# 使用说明：
#   1. 编辑本文件第 17 行，将 REPO_URL 替换为你的仓库地址
#   2. 在 git bash 中执行: bash push_to_github.sh
#
# 仓库格式：
#   https://github.com/<你的用户名>/<你的仓库名>.git
# 例：
#   https://github.com/zhangsan/my-skills.git
#   https://github.com/zhangsan/ai-github-scanner.git

set -e

# === 配置（请修改为你自己的仓库地址） ===
REPO_URL="https://github.com/<你的用户名>/<你的仓库名>.git"

# === 推送脚本 ===
cd "$(dirname "$0")"

echo "=== 1. 验证git仓库 ==="
if [ ! -d .git ]; then
  echo "✗ .git 目录不存在"
  exit 1
fi

echo "=== 2. 配置远程 ==="
git remote remove origin 2>/dev/null || true
git remote add origin "$REPO_URL"

echo "=== 3. 推送到 GitHub ==="
echo "目标仓库: $REPO_URL"
echo "分支: main"
git push -u origin main

echo ""
echo "=== ✅ 推送完成 ==="
echo "访问你的仓库: ${REPO_URL%.git}"
echo ""
echo "克隆到本地 skill 目录使用："
echo "  git clone $REPO_URL ~/.workbuddy/skills/ai-github-scanner"