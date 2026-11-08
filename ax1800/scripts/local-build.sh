#!/bin/sh
# 本地一键构建（WSL2 / Ubuntu 22.04，对应 .github/workflows/build.yml 的全部步骤）
#
# 用法：在源码树根目录执行
#   sh ax1800/scripts/local-build.sh [6144|12288]      # 默认 12288
#
# 前置：
#   - 编译依赖已装齐（见 build.yml 的 apt 列表）
#   - apk 签名私钥放在树根 private-key.pem（或用环境变量 APK_SIGNING_KEY_FILE 指路）；
#     没有则现场生成——旧固件将不信任新源，能重刷就没关系
#
# 产物：
#   bin/targets/qualcommax/ipq60xx/*factory.bin / *sysupgrade.bin / *.manifest / sha256sums
#   bin/apk-repo-out/          待推送的 apk 源（git 仓库，分支 apk-repo，已 commit）
#   bin/release-notes.md       Release 说明
#
# 编完后的推送/发布在 Windows 侧做（见脚本结尾打印的命令）。
set -eu

# WSL 默认把 Windows 的 PATH 追加进来（含带空格的 'Program Files\...' 条目），
# rust 安装步骤的 find -execdir 检测到非纯路径会直接拒绝执行。构建期间只用 Linux 原生路径。
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

KS="${1:-12288}"
case "$KS" in
	6144|12288) ;;
	*) echo "[x] 内核分区只支持 6144 或 12288（当前 '$KS'）" >&2; exit 1 ;;
esac
# 退出码自写文件：外层 wsl.exe 的 $? 中转不可靠，脚本自己落地退出码
trap 'echo $? > "$PWD/.build-exit"' EXIT
REPO_SLUG="huidegit/LibWrt-X-AX1800"
export TZ=Asia/Shanghai
# 本地以 root 运行（WSL 默认），GNU tar 的 configure 会拒绝 root 并要求显式放行；
# CI 是非 root 用户所以从没触发过这条
export FORCE_UNSAFE_CONFIGURE=1

step() { echo; echo "========== [$(date +%H:%M:%S)] $* =========="; }

# ---------- 0. 预检 ----------
step "0. 预检"
[ -f Makefile ] && [ -d target/linux ] || { echo "[x] 请在源码树根目录执行" >&2; exit 1; }
case "$PWD" in /mnt/*) echo "[x] 不要在 /mnt/*（Windows 盘）里编译——权限和性能都不行，源码放 WSL ext4" >&2; exit 1 ;; esac
for t in gcc make gawk flex bison rsync unzip curl git python3 openssl perl tar; do
	command -v "$t" >/dev/null || { echo "[x] 缺少工具 $t" >&2; exit 1; }
done
avail=$(df --output=avail -BG . | tail -1 | tr -dc '0-9')
echo "[i] 可用空间 ${avail}G，nproc=$(nproc)"
[ "$avail" -ge 25 ] || { echo "[x] 磁盘不足 25G" >&2; exit 1; }
# 重跑保险：清掉上次可能残留的生成物
rm -f .config feeds.conf
rm -rf files

# ---------- 1. feeds ----------
step "1. 更新 feeds（上游 + PassWall + 官方 iStore 源）"
cp feeds.conf.default feeds.conf
# PassWall：应用本体在 openwrt-passwall，C 依赖在 openwrt-passwall-packages
echo 'src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git' >> feeds.conf
echo 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git' >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
# luci feed（immortalwrt）自带 luci-app-passwall，feeds install 会优先装它，两处都认
test -f package/feeds/luci/luci-app-passwall/Makefile \
	|| test -f package/feeds/passwall/luci-app-passwall/Makefile \
	|| { echo "[x] luci-app-passwall 没装上（哪个 feed 里都没有）" >&2; exit 1; }
echo "[+] luci-app-passwall 来自: $(ls -d package/feeds/*/luci-app-passwall)"

# nss_packages 的 git 型包从 codelinaro（高通 QSDK 镜像）拉源码，上游会重写历史，
# feed 里锁定的 PKG_MIRROR_HASH 与本地重新生成的归档对不上（2026-11-08 实测
# qca-nss-drv Hash mismatch）。本地生成+本地使用，剥掉这些锁定哈希以信任当前源码。
for m in feeds/nss_packages/*/Makefile; do
	grep -q '^PKG_SOURCE_PROTO:=git' "$m" && sed -i '/^PKG_MIRROR_HASH:=/d' "$m"
done
echo "[+] nss_packages 的锁定哈希已剥离（git 型包）"

echo 'src-git istore https://github.com/linkease/istore.git' >> feeds.conf
./scripts/feeds update istore
# 这棵树的 scripts/feeds 不支持 ;<sha> 直拼（会被当分支名 clone 失败），更新后手动钉住
git -C feeds/istore checkout -q a97ace34f2da358a015b094d326bba2697697f2e
./scripts/feeds install -p istore luci-app-store luci-lib-taskd taskd luci-lib-xterm
test -f feeds/istore/luci/luci-app-store/Makefile || { echo "[x] istore feed 内容不对（luci-app-store 缺失）" >&2; exit 1; }

# 主题用 jerrykuku 的 argon 3.x，pin 到固定 commit（master 浮动会打挂构建）
./scripts/feeds uninstall luci-theme-argon luci-app-argon-config || true
rm -rf package/luci-theme-argon package/luci-app-argon-config
git init -q package/luci-theme-argon
git -C package/luci-theme-argon remote add origin https://github.com/jerrykuku/luci-theme-argon.git
echo "[i] 拉取 argon pinned commit…"
git -C package/luci-theme-argon fetch --depth 1 origin c6d63bd68aa9272e40c35cee5e615f45cc1e4eb0
git -C package/luci-theme-argon checkout -q FETCH_HEAD
test -f package/luci-theme-argon/Makefile || { echo "[x] argon Makefile 缺失" >&2; exit 1; }
grep -q 'PKG_VERSION:=3' package/luci-theme-argon/Makefile
echo "[+] argon 3.x 已就位（pinned）"

# ---------- 2. 生成 .config ----------
step "2. 生成 .config"
cat ax1800/config/device.config >> .config
cat ax1800/config/repos.config >> .config
cat ax1800/config/packages.config >> .config
cat ax1800/config/packages-store.config >> .config
if [ "$KS" != "6144" ]; then
	cat ax1800/config/kernel-dae.config >> .config
else
	echo "[w] 6144 模式：跳过 kernel-dae.config（BTF/XDP 内核装不进 6M 分区）"
fi
cat ax1800/config/apk-repo.config >> .config

sh ax1800/scripts/set-kernel-size.sh "$KS"

# 首启配置作为 rootfs 覆盖层；git 不保留可执行位，显式补上
mkdir -p files
cp -Rf ax1800/files/. files/
chmod +x files/etc/rc.local files/etc/uci-defaults/*
test -f files/etc/uci-defaults/99-ax1800

# apk 自建源：写死大号（不再用 ${GITHUB_REPOSITORY}，防止再次指向会被删的仓库）
mkdir -p files/etc/apk/repositories.d
{
	echo "https://raw.githubusercontent.com/${REPO_SLUG}/apk-repo/target/packages.adb"
	echo "https://raw.githubusercontent.com/${REPO_SLUG}/apk-repo/kmods/packages.adb"
} > files/etc/apk/repositories.d/00-ax1800.list
cat files/etc/apk/repositories.d/00-ax1800.list

make defconfig
echo "===== 生效的关键项 ====="
grep -E '^CONFIG_(TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01|PACKAGE_luci-theme-argon|PACKAGE_luci-app-store|PACKAGE_luci-app-passwall|PACKAGE_luci-app-usteer|PACKAGE_kmod-nft-fullcone|KERNEL_DEBUG_INFO_BTF|KERNEL_XDP_SOCKETS|VERSION_REPO)' .config || true
grep -q '^CONFIG_PACKAGE_luci-theme-argon=y$' .config \
	|| { echo "[x] argon 3.x 没被选中" >&2; exit 1; }
for s in kmod-nft-socket kmod-netlink-diag kmod-ipt-nat; do
	grep -q "^CONFIG_PACKAGE_$s=y$" .config \
		|| { echo "[x] $s 没被选中（PassWall 依赖它）" >&2; exit 1; }
done
grep -q '^CONFIG_PACKAGE_luci-app-passwall=y$' .config \
	|| { echo "[x] luci-app-passwall 没被选中" >&2; exit 1; }
grep -q '^CONFIG_PACKAGE_luci-app-store=y$' .config \
	|| { echo "[x] iStore 没被选中（查 feeds/istore 是否正常）" >&2; exit 1; }
nkm=$(grep -c '^CONFIG_PACKAGE_kmod-.*=m$' .config || true)
echo "ALL_KMODS 生效：$nkm 个 kmod 以 =m 参与编译"
[ "$nkm" -gt 800 ] || { echo "[x] ALL_KMODS 没生效（只看到 $nkm 个 kmod=m）" >&2; exit 1; }

# ---------- 3. 注入 root 密码 ----------
step "3. 注入 root 密码"
# 按用户决定：默认 root/root，刷机后自己改。'root' 无特殊字符，sed 直接换。
sed -i 's/__ROOT_PASSWORD__/root/' files/etc/uci-defaults/99-ax1800
if grep -q '__ROOT_PASSWORD__' files/etc/uci-defaults/99-ax1800; then
	echo "[x] 密码注入失败，占位符还在" >&2
	exit 1
fi
echo "[+] root 密码 = root（刷机后请自行修改）"

# ---------- 4. 签名密钥 ----------
step "4. apk 签名密钥"
KEY="${APK_SIGNING_KEY_FILE:-$PWD/private-key.pem}"
if [ ! -f "$KEY" ] && [ -n "${APK_SIGNING_KEY_FILE:-}" ]; then
	echo "[x] APK_SIGNING_KEY_FILE 指向的文件不存在：$KEY" >&2
	exit 1
fi
if [ ! -f "$KEY" ]; then
	echo "[w] 没找到 private-key.pem，本次构建现场生成密钥；旧固件将不信任新的 apk-repo"
	openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem
	KEY="$PWD/private-key.pem"
fi
chmod 600 "$KEY"
[ "$KEY" = "$PWD/private-key.pem" ] || cp -f "$KEY" private-key.pem
openssl ec -in private-key.pem -pubout > public-key.pem
echo "[+] 使用私钥 private-key.pem（指纹 $(openssl ec -in private-key.pem -pubout 2>/dev/null | openssl sha256 | awk '{print $2}' | cut -c1-16)…）"

# ---------- 5. 预下载 ----------
step "5. 预下载依赖"
make download -j"$(nproc)" || make download -j1
# dl/ 里 <1KB 的是 404 残骸，*.tmp 是中断的半成品，都会导致 md5 校验失败
find dl -type f \( -size -1024c -o -name "*.tmp" \) -delete

# ---------- 6. 编译 ----------
step "6. 编译（IGNORE_ERRORS=m：=m 的冷门 kmod 编不过就跳过，=y 仍硬失败）"
make -j"$(nproc)" IGNORE_ERRORS=m || make -j1 IGNORE_ERRORS=m || make -j1 V=s IGNORE_ERRORS=m

# ---------- 7. 校验产物 ----------
step "7. 校验产物"
T=bin/targets/qualcommax/ipq60xx
f=$(ls "$T"/*jdcloud_re-ss-01-squashfs-factory.bin | head -1)
echo "镜像: $f ($(stat -c%s "$f") 字节)"
magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
[ "$magic" = "d00dfeed" ] || { echo "[x] 不是 FIT 镜像（$magic）" >&2; exit 1; }
fit=$(od -An -tu4 -j4 -N4 --endian=big "$f" | tr -d ' ')
lim=$((KS * 1024))
echo "内核 FIT: ${fit} 字节 / ${lim} 字节分区"
[ "$fit" -le "$lim" ] || { echo "[x] 内核超过 ${KS}k，会写穿 rootfs" >&2; exit 1; }
sq=$(od -An -tx1 -j"$lim" -N4 "$f" | tr -d ' \n')
[ "$sq" = "68737173" ] || { echo "[x] ${KS}k 处不是 hsqs（$sq），内核/rootfs 边界异常" >&2; exit 1; }
echo "[+] 边界正确"

man=$(ls "$T"/*jdcloud_re-ss-01.manifest | head -1)
echo "manifest: $(wc -l < "$man") 个包"
for p in luci-theme-argon luci-app-store luci-app-openclash luci-app-usteer \
         luci-app-passwall luci-app-autoreboot luci-app-samba4 luci-app-diskman \
         kmod-nft-fullcone kmod-nft-socket kmod-netlink-diag kmod-ipt-nat \
         kmod-usb-storage kmod-fs-ntfs3 \
         kmod-qca-nss-drv kmod-qca-nss-ecm ipq-wifi-jdcloud_re-ss-01 kmod-ath11k; do
	grep -q "^$p " "$man" || { echo "[x] 固件里没有 $p" >&2; exit 1; }
done
echo "[+] 关键包都在（含 PassWall 全套依赖）"

# ---------- 8. 准备 apk 源（apk-repo-out，稍后从 Windows 侧推送）----------
step "8. 准备 apk 源"
[ -d "$T/packages" ] || { echo "[x] $T/packages 不存在；$T 下实际有：$(ls -1 "$T" 2>/dev/null | tr '\n' ' ')" >&2; exit 1; }

OUT="$PWD/bin/apk-repo-out"
rm -rf "$OUT"
mkdir -p "$OUT/target" "$OUT/kmods"
# 只发官方源给不了的两类：kernel（带本机 config 哈希）和 kmod-*（依赖那个哈希）
for f in "$T"/packages/kmod-*.apk;  do [ -e "$f" ] && cp -f "$f" "$OUT/kmods/";  done
for f in "$T"/packages/kernel-*.apk; do [ -e "$f" ] && cp -f "$f" "$OUT/target/"; done
nk=$(find "$OUT/kmods" -maxdepth 1 -name '*.apk' | wc -l)
nt=$(find "$OUT/target" -maxdepth 1 -name '*.apk' | wc -l)
echo "kmods: $nk 个，target: $nt 个"
[ "$nk" -gt 100 ] || { echo "[x] kmods 只有 $nk 个，明显不对" >&2; exit 1; }
[ "$nt" -ge 1 ] || { echo "[x] 没找到 kernel 包" >&2; exit 1; }

APK="$PWD/staging_dir/host/bin/apk"
[ -x "$APK" ] || { echo "[x] 找不到 staging_dir/host/bin/apk" >&2; exit 1; }
KEY=$PWD/private-key.pem
[ -f "$KEY" ] || { echo "[x] private-key.pem 不存在" >&2; exit 1; }
cp -f public-key.pem "$OUT/"
echo "[+] 公钥已随源一起发布"

# ---- 额外包：镜像里装了、但官方/iStore 源都没有的自编包 ----
OFF=https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT
APKG=aarch64_cortex-a53
rm -rf /tmp/known-idx; mkdir -p /tmp/known-idx
i=0
for u in "$OFF/packages/$APKG/base" "$OFF/packages/$APKG/luci" \
         "$OFF/packages/$APKG/packages" "$OFF/packages/$APKG/routing" \
         "$OFF/packages/$APKG/telephony" \
         "$OFF/targets/qualcommax/ipq60xx/packages" \
         https://istore.istoreos.com/repo-apk/all/nas_luci \
         https://istore.istoreos.com/repo-apk/all/store \
         https://istore.istoreos.com/repo-apk/all/meta \
         https://istore.istoreos.com/repo-apk/all/compat \
         https://istore.istoreos.com/repo-apk/aarch64_generic/nas; do
	i=$((i+1))
	curl -fsSL --retry 3 --max-time 90 "$u/packages.adb" -o "/tmp/known-idx/$i.adb" \
		|| echo "[w] 索引没下到：$u"
done
: > /tmp/known-names
for f in /tmp/known-idx/*.adb; do
	[ -e "$f" ] || continue
	$APK --allow-untrusted adbdump --format json "$f" 2>/dev/null \
		| grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' >> /tmp/known-names || true
done
sort -u -o /tmp/known-names /tmp/known-names
kn=$(wc -l < /tmp/known-names)
echo "官方/iStore 已知包名 $kn 个"
[ "$kn" -gt 5000 ] || { echo "[x] 已知包名只有 $kn 个，索引没下全" >&2; exit 1; }

MAN=$(ls "$T"/*.manifest 2>/dev/null | head -1)
ne=0
for n in $(awk '{print $1}' "$MAN" | sort -u); do
	case "$n" in kmod-*|kernel*) continue ;; esac
	if grep -qxF "$n" /tmp/known-names; then continue; fi
	for f in bin/packages/$APKG/*/"$n"-[0-9]*.apk "$T"/packages/"$n"-[0-9]*.apk; do
		[ -e "$f" ] || continue
		cp -f "$f" "$OUT/target/"
		echo "  + 额外包 $n"
		ne=$((ne+1))
		break
	done
done
echo "额外包 $ne 个"
[ "$ne" -ge 1 ] || echo "[w] 没找到额外包，nss-firmware 那几个应该在里面"

for d in target kmods; do
	( cd "$OUT/$d"
	  n=$(find . -maxdepth 1 -name '*.apk' | wc -l)
	  [ "$n" -gt 0 ] || { echo "[x] $d 目录没有 .apk" >&2; exit 1; }
	  $APK mkndx --root . --keys-dir . --allow-untrusted --output packages.adb ./*.apk
	  before=$(stat -c%s packages.adb)
	  # apk 3.0.5 的 mkndx 没有 --sign；签名要 adbsign 写进 packages.adb 本身
	  $APK --sign-key "$KEY" --keys-dir "$OUT" --allow-untrusted adbsign --reset-signatures packages.adb
	  after=$(stat -c%s packages.adb)
	  [ "$after" -gt "$before" ] || { echo "[x] $d 的索引没签上（$before -> $after 字节）" >&2; exit 1; }
	  echo "[+] $d: $n 个包，$(du -sh . | cut -f1)，索引 $after 字节"
	)
done

$APK --allow-untrusted adbdump --format json "$OUT/target/packages.adb" > /tmp/idx-target.json 2>/dev/null || true
$APK --allow-untrusted adbdump --format json "$OUT/kmods/packages.adb"  > /tmp/idx-kmods.json  2>/dev/null || true
grep -qE '"name": *"kernel"' /tmp/idx-target.json || echo "[w] target 索引里没找到 kernel 包名"
grep -q 'kmod-mac80211' /tmp/idx-kmods.json || echo "[w] kmods 索引里没找到 kmod-mac80211"

# 打包成 git 仓库（分支 apk-repo），推送在 Windows 侧做（那边有 gh 凭据）
( cd "$OUT"
  git init -q
  git checkout -q --orphan apk-repo
  git add -A
  git -c user.name="ax1800-local" -c user.email="ax1800@local" \
      commit -q -m "apk-repo: kmod $(date -u +%Y-%m-%dT%H:%M:%SZ)"
)
echo "[+] apk 源已备好：$OUT（分支 apk-repo，待推送）"

# ---------- 9. Release 说明 ----------
step "9. 生成 Release 说明"
kver=$(grep -oP 'LINUX_KERNEL_HASH-\K[0-9.]+' target/linux/generic/kernel-6.12 2>/dev/null || echo unknown)
gitsha=$(git rev-parse --short HEAD 2>/dev/null || echo local)
{
	echo "## 本次固件"
	echo "- 内核 $kver，内核分区 ${KS}k，FIT ${fit} 字节，固件包 $(wc -l < "$man") 个"
	echo "- 基于 commit \`$gitsha\`（本地构建 $(date +%Y-%m-%d)）"
	echo "- PassWall 已内置；全量 kmod 见 apk 源"
	echo
	echo "## apk 源"
	echo "- 分支：https://github.com/${REPO_SLUG}/tree/apk-repo"
	echo "- 固件内置：https://raw.githubusercontent.com/${REPO_SLUG}/apk-repo/target/packages.adb"
	echo "- 固件内置：https://raw.githubusercontent.com/${REPO_SLUG}/apk-repo/kmods/packages.adb"
	echo
	echo "## 刷写"
	echo "- 12M 表：U-Boot \`/firmware.html\` 刷 \`*factory.bin\`"
	echo "- 已在本固件上：LuCI 升级或用 \`sysupgrade *sysupgrade.bin\`"
	echo
	echo "## root 密码"
	echo "- 默认 root/root，刷完请立即修改"
} > bin/release-notes.md
cat bin/release-notes.md

# ---------- 完成 ----------
step "构建完成"
echo "镜像:   $PWD/$f"
echo "        $PWD/$T/*sysupgrade.bin"
echo "apk源:  $OUT  (分支 apk-repo，已 commit 待推送)"
echo "说明:   $PWD/bin/release-notes.md"
echo
echo "===== 下一步（在 Windows Git Bash 里执行）====="
echo "1. 推 apk 源（首次用 -f 覆盖旧分支）："
echo "   git -C \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/bin/apk-repo-out\" push -f https://github.com/${REPO_SLUG}.git apk-repo"
echo "2. 发 Release："
echo "   gh release create ax1800-<日期>-local --repo ${REPO_SLUG} --notes-file \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/bin/release-notes.md\" \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/$T/*factory.bin\" \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/$T/*sysupgrade.bin\" \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/$T/*.manifest\" \"//wsl.localhost/Ubuntu-22.04/root/LibWrt/$T/sha256sums\""
