#!/bin/sh
# 构建产物发布（在 Windows Git Bash 里执行；依赖 gh 已登录且有权限的账号）
#
# 用法：sh ax1800/scripts/publish.sh
#
# 功能：
#   1. 从 WSL 拷出 apk-repo-out 并 force-push 到大号的 apk-repo 分支
#   2. 创建或更新单条目 Release（tag 固定 ax1800-local，资产 --clobber 覆盖）
#      —— 单条目模式（EmptyGhost 同款）：不刷屏，永远只有一个"最新本地构建"
# 前置：local-build.sh 已成功跑完（bin/apk-repo-out 与 bin/targets 均存在）
set -eu

REPO_SLUG="huidegit/LibWrt-X-AX1800"
TAG="ax1800-local"
WSL='//wsl.localhost/Ubuntu-22.04/root/LibWrt'
T="$WSL/bin/targets/qualcommax/ipq60xx"

echo "[1/3] 拷出 apk-repo 并 force-push…"
rm -rf apk-repo-push
cp -r "$WSL/bin/apk-repo-out" apk-repo-push
git -C apk-repo-push push -f "https://github.com/${REPO_SLUG}.git" apk-repo

echo "[2/3] 创建或更新 Release（单条目：$TAG）…"
NOTES="$WSL/bin/release-notes.md"
gh release create "$TAG" --repo "$REPO_SLUG" \
	--title "AX1800 本地构建（持续更新）" --notes-file "$NOTES" 2>/dev/null \
	|| gh release edit "$TAG" --repo "$REPO_SLUG" \
		--title "AX1800 本地构建（持续更新）" --notes-file "$NOTES"

echo "[3/3] 上传资产（--clobber 覆盖旧资产）…"
rm -rf assets-push && mkdir assets-push
cp "$T"/*factory.bin "$T"/*sysupgrade.bin "$T"/*.manifest "$T/sha256sums" assets-push/
cd assets-push
gh release upload "$TAG" --repo "$REPO_SLUG" --clobber \
	libwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin \
	libwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin \
	libwrt-qualcommax-ipq60xx-jdcloud_re-ss-01.manifest \
	sha256sums
cd ..

echo
echo "[✓] 发布完成: https://github.com/${REPO_SLUG}/releases/tag/$TAG"
echo "    apk 源:    https://github.com/${REPO_SLUG}/tree/apk-repo"
