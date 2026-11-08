# LibWrt X AX1800

京东云亚瑟 AX1800 Pro（IPQ6000 / `ipq6018-jdcloud_re-ss-01`）的自编固件仓库。

底座是 [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) `25.12-nss`（**apk** 包管理，内核 6.12），
本仓库是它的 fork：上游源码原样保留，所有定制集中在 `ax1800/` 下，同步上游用 merge 而不是强推。

> 上游 README（NSS 功能矩阵、设备支持范围）见 [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt)。
> 本仓库关心的只有这一台机器。

---

## 这台机器

| 项 | 值 |
|---|---|
| 机型 | 京东云亚瑟 AX1800 Pro，`ipq6018-jdcloud_re-ss-01` |
| SoC | IPQ6000（qualcommax / ipq60xx），ath11k 无线 + NSS 硬件加速 |
| 运存 | **1 GiB（硬改）**，`free` 显示 ~878 MiB 正常（Q6 保留区 85 MiB） |
| eMMC | 30,212,096 扇区 = 14.41 GiB，扇区 512 B |
| 分区表 | GPT，**12M 布局**：`0:HLOS` 12 MiB、rootfs 2 GiB、`p27` 数据盘 11.42 GiB |
| U-Boot | chenxin527 版；网页只有 `/firmware.html`、`/ptable.html`、`/backup.html` 等 |

完整分区表、设备号换算（`mmcblk0pN` 的 N = 表里 `#` − 1）、偏移与刷机顺序：
**[ax1800/device-partitions.md](ax1800/device-partitions.md)** —— 动分区前必须先看。

---

## 固件里有什么

- **NSS 全套硬件加速**：`kmod-qca-nss-drv*` / `-ecm`，PPPoE、L2TP、GRE、VLAN 走 NSS 核心
- **代理**：OpenClash（含 dnsmasq-full / ruby / kmod-tun / kmod-nft-tproxy）、PassWall
  （本体编进镜像，xray/sing-box 等核心运行时在 LuCI 里自己下）
- **网络**：usteer（双频合一频段引导）、ddns + 阿里云/Cloudflare/DNSPod 脚本、sqm-scripts-nss、UPnP、WOL、无线连接历史
- **全锥 NAT1**：`firewall4` fullcone（LibWrt 自带补丁 + `kmod-nft-fullcone`）
- **存储**：Samba4、diskman、automount、USB 与 ext4/vfat/exfat/ntfs3/btrfs 驱动、nls（含 cp936）
- **远程**：WireGuard
- **系统**：ttyd、commands、autoreboot、zram-swap、iStore（`luci-app-store`）、argon 3.x 主题
- **中文界面**：常用 LuCI 应用的中文语言包
- **dae**：只开了内核能力（BTF / XDP / kprobe / bpf 事件），**dae 本体不装**，以后单独装

插件全表（用途 / 依赖 / 注意事项）见 **[ax1800/plugin-catalog.md](ax1800/plugin-catalog.md)**。

## 开箱默认值

| 项 | 值 |
|---|---|
| 管理地址 | `192.168.1.1` |
| 账号 / 密码 | `root` / `root`（**固定值，刷完第一件事改掉**） |
| WiFi | 双频合一，SSID `CLI`，加密 `sae-mixed`（WPA2-PSK + WPA3-SAE 混合），密码 `12345678` |
| 无线参数 | 2.4G `HE20`（保 20MHz 又不丢 WiFi6）、5G `HE80`、`channel=auto`、`country=CN`、11k/11v 开、11r 关 |
| WAN | **DHCP**（拨号命令见下） |
| IPv6 | LAN 侧已开（`ip6assign=60` + RA/DHCPv6 server），`wan6=dhcpv6` |
| 主题 | argon 3.x |

> ⚠️ 默认口令（root/root、WiFi 12345678）只适合内网自用。固件会自动发布到公开 Release，
> 介意的话把仓库转私有，或在 `99-ax1800` 里改掉默认值。

### 改拨号

```sh
uci set network.wan.proto='pppoe'
uci set network.wan.username='宽带账号'
uci set network.wan.password='宽带密码'
uci set network.wan.ipv6='1'
uci commit network && /etc/init.d/network restart
```

---

## 自动构建与发布

```
WSL2（当前主用）  local-build.sh   feeds(lock 钉子) → 配置 → 编译 → 校验 → 差分打包 apk 源
      ↓
Windows 侧        publish.sh       推 apk-repo 分支 + 单条目 Release（tag 固定 ax1800-local）
```

- **本地构建（WSL2）为主**：`sh ax1800/scripts/local-build.sh 12288`，一条龙到出镜像和
  apk-repo 打包（含 CRLF 守卫、镜像内容自检、feeds.lock 钉子）。
- **发布**：`sh ax1800/scripts/publish.sh`（Windows Git Bash）——推 apk-repo 分支 +
  创建/更新固定条目 `ax1800-local`（资产覆盖，不刷屏）。详见
  **[ax1800/README.md](ax1800/README.md#构建)**。
- **GitHub Actions（备用）**：大号 Actions 账单锁定期间不可用；恢复后手动触发
  Actions → **Build AX1800 12M**（`kernel_size` 默认 `12288`）。
- **sync-upstream.yml 已暂停**每日自动同步与构建派发（账单锁定期间空跑无意义），
  恢复方法见该文件内注释。
- `.upstream-state` 记录「已成功构建的上游 SHA」；构建失败不写，下次自动重试。
- Release 正文自动生成：本次固件体积与包数、apk 源地址、刷写说明。

产物 `bin/targets/qualcommax/ipq60xx/*factory.bin`（U-Boot `/firmware.html`）与 `*sysupgrade.bin`。

---

## 软件源

固件是 **apk**（LibWrt 默认 `CONFIG_USE_APK=y`），内置 `openwrt-25.12.pem` 与 `immortalwrt-25.12.pem`。

| 源 | 包数（aarch64_cortex-a53） |
|---|---:|
| **immortalwrt 25.12-SNAPSHOT**（已选） | **10,157** |
| openwrt `releases/packages-25.12` | 8,596 |
| openwrt snapshots | 9,798 |
| `dl.openwrt.ai` | 只有 `.ipk`，apk 固件用不了 |

约束与解法：自编内核的 kmod 与 NSS 私有包任何官方源都没有（官方 buildbot 同病）——
**解法见下节自建 apk 源**，`kmod-*` 从自建源装（内核哈希对得上），用户空间包走官方活源。

---

## 目录

```
ax1800/
  README.md              构建与首启说明
  device-partitions.md   设备与分区事实底稿
  plugin-catalog.md      插件清单（用途/依赖/注意事项）
  config/                配置片段（机型、包、iStore、dae 内核+1GB 优化、软件源、自建源开关、feeds.lock）
  files/                 rootfs 覆盖层（首启脚本 / rc.local 源自愈）
  scripts/               set-kernel-size.sh（12M 内核分区改写）
                         local-build.sh（本地一键构建，WSL2）
                         publish.sh（发布：推 apk-repo + 单条目 Release，Windows 侧）
.github/workflows/
  build.yml              构建 + 校验 + apk 源差分发布（Actions 备用）
  sync-upstream.yml      上游同步（已暂停，见文件内注释）
```

## 已知坑

- 6M / 12M 固件**不能互刷**，`sysupgrade` 不检查分区边界
- **别装 `owut` / `luci-app-attendedsysupgrade`**：ASU 用官方 ImageBuilder 重建，定制全丢
- `luci-i18n-*` 是 HIDDEN 符号，直接写 `.config` 会被 `defconfig` 静默丢弃
- 跑代理前别开软件卸载（`flow_offloading`），否则部分流量绕过 TUN/TPROXY
- 路由器上没有 `od`、`timeout`、`partx`、`sgdisk`、`fdisk`；有 `parted`、`blkid`、`mkfs.ext4`
- busybox ash **不认 `$'...'`**
- **`apk` 每次事务都报 `1 error`（已有解法，见下节自建 apk 源）**：镜像里 452 个包全被写进 `/etc/apk/world`，其中 166 个 `kmod-*` 绑死本机编译哈希 `kernel=6.12.112~7b482d99…`，公共源里是 `cf8cd0bb…`，任何已配置仓库都找不到它们。注意 apk 的检查对象是**已安装包集合**（`/lib/apk/db/installed`），不是 world：实测把 world 里的 kmod 全删掉，`apk add -s luci-base` 退出码仍是 1，反而把这些包变成孤儿，`apk upgrade` 会计划 Purging 78 个（含 `kmod-mac80211`/`kmod-ath11k`，WiFi 当场没了）。**所以不要裁 world**。根治只有一条路：把自编译产物 `bin/targets/qualcommax/ipq60xx/packages/` 和 `kmods/<内核版本>/` 发布成一个 apk 源，让 apk 真的找得到这 166 个包。在那之前，`1 error` 只影响退出码，装包本身是成功的（iStore / OpenClash 会误判成失败）。
- **别 `apk upgrade` 整个系统**：源里的内核是另一个编译哈希，升级内核会让现有全部 kmod 失配（无线、NSS、文件系统模块全挂）。装单个包用 `apk add 包名` 就行。
- **别照着 apk 的 `NOTE: Consider running apk upgrade with --prune and/or --available` 做**：`--prune` 会把 90 个包当孤儿清掉（`kmod-fs-f2fs`、`kmod-leds-gpio`、`kmod-gpio-button-hotplug`、`kmod-dsa`/`kmod-dsa-qca8k`、`kmod-thermal`、`kmod-qcom-qmi-helpers`、`kmod-qrtr`、`kmod-mhi-bus`、`kmod-phylink`、`kmod-regmap-core` …），`--available` 会把 99 个包替换成源里的版本。这台机器的内核是打 NSS 补丁自编译的，两条跑下去当场失能。那条 NOTE 是 apk 的通用建议，在「内核非官方」的场景下是陷阱。
- **包源被换成 `mirrors.vsean.net`（已处理）**：`default-settings-chn` 首启会把 `/etc/apk/repositories.d/distfeeds.list` 里的 `downloads.immortalwrt.org` 全换成 `system.@imm_init[0].apk_mirror`，它的默认值是 `https://mirrors.vsean.net/openwrt`。这个域名现在只回一个跟不过去的 302（日志里是 `wget: exited with error 8` / `unexpected end of file`），六个源索引全刷不下来，`apk update` 就又凑出 1 个 error —— 和 world 那 175 条是两回事。固件里做了双保险：`/etc/uci-defaults/99-ax1800` 先把 `apk_mirror` 钉成官方源（它排在 `99-default-settings-chinese` 前面，对方的 sed 变成空操作），`/etc/rc.local` 每次开机再把残留的 vsean 地址改回来。

## 自建 apk 源（apk-repo 分支）

固件里 166 个 `kmod-*` 绑死本机内核哈希（`kernel=6.12.112~7b482d99…`），公共源里永远没有这一份，
apk 每次事务都会记 1 个 error。根治办法是自己发源：

- 构建完成后（本地 `local-build.sh` 或 CI），从 `bin/targets/qualcommax/ipq60xx/packages/` 里挑出 `kmod-*` 和 `kernel-*`
  两类包（本地 `make` 不生成 `kmods/<内核版本>/`，那种分层只有官方 buildbot 才有，
  全量产物都平铺在 `packages/` 下），用 `apk mkndx` 重新打索引，force-push 到本仓库的
  `apk-repo` 分支。每次一个孤儿提交，历史永远只有 1 个 commit，不会把仓库撑爆。
- kmod 是**全编**的（`CONFIG_ALL_KMODS=y`，约 1100 个、合计 45 MB 上下）。产物是 `m`——编出来
  但不装进 rootfs，所以镜像体积不变，而任何插件的 kmod 依赖都能从 `apk-repo` 装上。普通软件包
  仍走 distfeeds 里的官方源。
- 固件构建时自动生成 `/etc/apk/repositories.d/00-ax1800.list`，指向（**写死大号，不再用变量**）：
  `https://raw.githubusercontent.com/huidegit/LibWrt-X-AX1800/apk-repo/target/packages.adb` 和
  `.../apk-repo/kmods/packages.adb`。
- 用 raw 不用 Release：Releases 会 302 到 `objects.githubusercontent.com`，apk 不跟跨域跳转，
  会重演 `mirrors.vsean.net` 那个 `wget: exited with error 8`。

**签名**：apk 只信任 `/etc/apk/keys/` 里的公钥。索引由 CI 用 `apk --sign-key … adbsign` 签名，
签名块直接写在 `packages.adb` 里面（apk v3 的索引没有 `.sig` 文件）。这里有个坑：`apk mkndx`
**不支持** `--sign`，那个 `--sign` 只是全局 `--sign-key` 的缩写，只加载密钥、不产出签名，
所以必须再跑一次 `adbsign`；而且 `adbsign` 读入索引时也要过 adb 校验，必须带 `--allow-untrusted`，
否则会打印 `ERROR: packages.adb: UNTRUSTED signature` 然后原样退出（返回码还是 0）。
公钥由 base-files 装进镜像，同时随源一起发布。私钥：**本地构建放树根 `private-key.pem`**
（gitignored，绝不入库；也可用环境变量 `APK_SIGNING_KEY_FILE` 指路），CI 构建则放仓库
Secret `APK_SIGNING_KEY`。私钥必须跨构建复用，否则：

```sh
openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem   # 仅首次生成
```

换新钥后，之前刷的旧镜像就不认新源了（表现为 `apk update` 报 UNTRUSTED signature），
必须重刷固件。

验证：`apk update` 应看到多出两条 raw 源、退出码 0；`apk add -s luci-base` 退出码 0，
不再出现 `The following packages are no longer available from a repository`。

## 许可

上游 LibWrt / OpenWrt 均为 GPL-2.0，本仓库继承。
