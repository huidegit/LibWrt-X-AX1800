# LibWrt X AX1800

京东云亚瑟 AX1800 Pro（IPQ6000 / `ipq6018-jdcloud_re-ss-01`）的自编固件。
底座是 [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) `25.12-nss`（apk 包管理），本仓库是它的 fork，
所有定制都放在 `ax1800/` 下，不动上游源码。

---

## 文件

| 路径 | 内容 |
|---|---|
| `ax1800/device-partitions.md` | **设备与分区事实底稿**：eMMC 28 项分区、设备号换算、6M/12M 边界、GPT 修复、`p27` 数据盘、刷机顺序、备份 MD5 与恢复 |
| `ax1800/plugin-catalog.md` | 可编译插件清单：用途、依赖、注意事项 |
| `ax1800/config/device.config` | 机型、版本串、中文默认设置、主题 |
| `ax1800/config/packages.config` | 选中的软件包（代理/网络/存储/远程/工具/中文） |
| `ax1800/config/packages-store.config` | iStore（`luci-app-store`）及其依赖 |
| `ax1800/config/kernel-dae.config` | dae 需要的内核能力（**只开内核，dae 本体以后单独装**） |
| `ax1800/config/repos.config` | 运行时 apk 源与 feed 开关 |
| `ax1800/config/apk-repo.config` | 自建 apk 源的构建开关（SIGNED_PACKAGES） |
| `ax1800/config/kernel-dae.config` | dae 内核能力 + **1GB 内存画像与 NSS 性能优化** |
| `ax1800/config/feeds.lock.json` | feed 钉子：全部 feed 锁到已知良好提交（删掉本文件即恢复浮动更新） |
| `ax1800/files/etc/uci-defaults/99-ax1800` | 首启配置：IPv6、NAT1、双频合一 WiFi、时区、主题 |
| `ax1800/scripts/set-kernel-size.sh` | 内核分区 6144k → 12288k（12M 表必须） |
| `ax1800/scripts/local-build.sh` | **本地一键构建**（WSL2）：feeds→config→编译→校验→apk 源打包 |
| `ax1800/scripts/publish.sh` | **发布脚本**（Windows 侧）：推 apk-repo + 单条目 Release |
| `.github/workflows/build.yml` | GitHub Actions 构建流程（账单恢复后可用） |

---

## 这台机器

| 项 | 值 |
|---|---|
| 机型 | 京东云亚瑟 AX1800 Pro，`ipq6018-jdcloud_re-ss-01` |
| SoC | IPQ6000（qualcommax / ipq60xx），ath11k + NSS 硬件加速 |
| 运存 | **1 GiB（硬改）**，`free` 显示 ~878 MiB 正常（Q6 保留区 85 MiB） |
| eMMC | 30,212,096 扇区 = 14.41 GiB，扇区 512 B |
| 分区表 | GPT，**12M 布局**：`0:HLOS` 12 MiB、rootfs 2 GiB、`p27` 数据盘 11.42 GiB |
| U-Boot | chenxin527 版；网页只有 `/firmware.html`、`/ptable.html`、`/backup.html` 等 |

分区与刷机细节见 [ax1800/device-partitions.md](ax1800/device-partitions.md)。

---

## 构建

### 本地构建（WSL2，当前主用）

前置：WSL2 + Ubuntu 22.04，编译依赖装齐（清单见 `build.yml` 的 apt 步骤），源码放 **ext4**（不要放 /mnt/c）。
建议 16 核 / 20G 内存 / 60G 磁盘。apk 签名私钥放树根 `private-key.pem`（gitignored，绝不入库）。

```sh
git clone --depth 1 -b 25.12-nss https://github.com/huidegit/LibWrt-X-AX1800.git ~/LibWrt
cd ~/LibWrt
sh ax1800/scripts/local-build.sh 12288        # 12M 表；原厂 6M 表传 6144
```

脚本一条龙：feeds（**全 feed 按 `feeds.lock.json` 钉到已知良好提交**）→ 合并配置片段
→ `set-kernel-size.sh` → CRLF 守卫（`\r` 会毁 init 脚本 shebang）→ 密码注入（默认 `root`）
→ `make download` → `make IGNORE_ERRORS=m`（=m 的冷门 kmod 编不过自动跳过）→
FIT/manifest 校验 → **镜像内容自检**（解包 sysupgrade 验证关键文件与源地址真的在 rootfs 里）→
**差分打包自建 apk 源**到 `bin/apk-repo-out/`（kmod 全量 + 官方源没有的私有包，索引已签名）。

编完后在 Windows 侧一条命令发布（**单条目 Release 模式**：tag 固定 `ax1800-local`，
每次构建更新同一条目，资产 `--clobber` 覆盖，不刷屏）：

```sh
sh ax1800/scripts/publish.sh
```

产物：`*factory.bin`（U-Boot 刷写）、`*sysupgrade.bin`（LuCI 升级）、
Release 页固定为 `ax1800-local`。

### GitHub Actions（备用）

大号 Actions 账单锁定期间不可用；恢复后 Actions → **Build AX1800 12M** → Run workflow
（`kernel_size` 默认 12288）。`sync-upstream.yml` 的每日自动同步与构建派发已暂停，
恢复方法见该文件注释。

---

## 首启做了什么

`ax1800/files/etc/uci-defaults/99-ax1800` 在第一次开机时执行一次：

| 项 | 设置 |
|---|---|
| **root 密码** | **`root`（默认）——刷完第一件事改掉**：`passwd root` |
| 主机名 / 时区 | `OpenWrt` / `Asia/Shanghai`，NTP 走阿里云 + cn.pool |
| IPv6 | LAN `ip6assign=60` + RA/DHCPv6 server（`ra_flags` 按 list 逐条 `add_list`）；`wan6=dhcpv6` |
| WAN | **默认 DHCP**（以后拨号见下） |
| 全锥 NAT | `firewall.@defaults[0].fullcone=1`（NAT1），`fullcone6=0` |
| WiFi | 双频合一，SSID `CLI`，加密 `sae-mixed`（WPA2-PSK + WPA3-SAE 混合），密码 `12345678` |
| 无线参数 | 2.4G `HE20`（保 20MHz 又不丢 WiFi6）、5G `HE80`、`channel=auto`、`country=CN`、11k/11v 开、11r 关、PMF 可选 |
| 自检 | 首启自检 radio 数量 ≥2 + 值里无引号，不过就不写标记、下次开机重试 |
| 卸载 | `flow_offloading` 保持关闭（代理要接管流量；硬件加速由 NSS 负责） |
| 主题 | argon（`/luci-static/argon`） |

### 以后改拨号

```sh
uci set network.wan.proto='pppoe'
uci set network.wan.username='宽带账号'
uci set network.wan.password='宽带密码'
uci set network.wan.ipv6='1'
uci commit network && /etc/init.d/network restart
```

光猫桥接时 DHCP 拿不到地址，这一步不做就上不了网。

---

## 全锥 NAT

LibWrt 自带 `firewall4` 的 fullcone 补丁和 `fullconenat-nft`（提供 `kmod-nft-fullcone`），
不需要 turboacc。首启脚本已写死 `fullcone=1`，验证：

```sh
uci get firewall.@defaults[0].fullcone     # 1
lsmod | grep nft_fullcone                  # 有模块
```

---

## dae

**只开了内核能力**（BTF / XDP / kprobe / bpf 事件），dae 与 luci-app-dae 本体以后单独装。
BTF 段在 arm64 上约 5 MiB，进 FIT 后 +1.5~2 MiB —— 6 MiB 分区放不下，只有 12M 能带。

以后装 dae 时确认 `CONFIG_HAS_BPF_TOOLCHAIN` 与内核 `.config` 里的
`DEBUG_INFO_BTF=y` / `XDP_SOCKETS=y` 真的生效（配置里写了不等于没被 depends 丢掉）。

---

## 1GB 内存与 NSS 性能优化（kernel-dae.config）

本设备是 1 GiB 硬改机，配置里叠了一组 ZqinKing 亚瑟档案同款的优化（符号均已在 LibWrt 树内验证）：

| 配置 | 作用 |
|---|---|
| `IPQ_MEM_PROFILE_256` | SoC 内存画像 256M 档：内核缓冲更保守，可用内存更多 |
| `ATH11K_MEM_PROFILE_512M` | ath11k WiFi 驱动小内存方案 |
| `NSS_MEM_PROFILE_HIGH` | NSS NAT 表项高配（1GB 内存撑得住） |
| `NSS_FIRMWARE_VERSION_11_4` | 钉 NSS 固件 11.4（与 laipeng668 nss_packages 匹配） |
| `KERNEL_SKB_RECYCLER(+MULTI_CPU)` | SKB 回收器：QSDK 的 NAT 多核性能利器 |
| `NSS_DRV_WIFI_MESH_ENABLE` + `ATH11K_NSS_MESH_SUPPORT` + `MAC80211_MESH` | NSS Mesh 卸载（双频合一/mesh 场景） |
| `kmod-qca-mcs` | NSS 组播卸载 |
| NSS PPPoE/PPTP 卸载 | LibWrt target 默认已含（qualcommax/Makefile），拨号场景白捡 |

代价说明：`IPQ_MEM_PROFILE_256` 是行为变更（内核缓冲保守换可用内存），对跑代理/Docker 的 1GB 机是正收益；
极端吞吐场景理论上略吃亏。ZqinKing 在同款 1GB 亚瑟上实测用这套。

---

## 软件源与自建 apk-repo

固件是 **apk**（LibWrt 默认 `CONFIG_USE_APK=y`）。内置三把钥匙：
`openwrt-25.12.pem`、`immortalwrt-25.12.pem`（官方）+ `public-key.pem`（自建源签名钥，与构建私钥配对）。

### 运行时源（`/etc/apk/repositories.d/`）

| 源 | 内容 |
|---|---|
| `00-ax1800.list` | **自建 apk-repo**（写死 `huidegit/LibWrt-X-AX1800`，kmods 全量 + 差分私有包） |
| `distfeeds.list` | immortalwrt 25.12-SNAPSHOT 的 base/luci/packages/routing/telephony（活源，剔除了上游模板里的 6 个死链） |
| `compat.list` | iStore 官方 compat 源 |

### 为什么必须有自建源（1 error 的来龙去脉）

apk 每次装/卸/升级事务结束都会解析 `/etc/apk/world`（全部已装包名），**任何名字在所有源索引里都搜不到就计 1 error、退出码 1**，iStore/LuCI 按退出码判成败。自编内核的 1130 个 kmod 依赖 `kernel (= 6.12.112~自编哈希)`，官方源永远对不上；NSS 私有包（nss-firmware 三件套、sqm-scripts-nss、ipq-wifi-jdcloud）任何官方源都不发——**官方 LibWrt buildbot 自己也是这个病**（12 个 distfeeds 死 6 个，同款 1 error）。裁 world 实测会触发 Purging 灾难，唯一正解就是把自编产物发布成签名源。

- `CONFIG_ALL_KMODS=y` → 1130 个 kmod 以 `=m` 编出（不进镜像、不进 world），全部进 apk-repo 供按需安装
- 差分逻辑：镜像 manifest 减去官方/iStore 索引已有的，剩下的（nss-firmware 三件套、ipq-wifi-jdcloud 等）从本地产物捞进 `target/`
- **在线只装用户空间包**；`kmod-*` 一律从自建源装（内核哈希对得上）
- 别删大号仓库——上一次小号被删，设备源 URL 全灭，1 error 立刻回来

---

## 已知坑

- **root 默认密码 `root`**，刷完立即改：`passwd root`
- 路由器上没有 `od`、`timeout`、`partx`、`blockdev`、`sgdisk`、`fdisk`；有 `parted`、`blkid`、`mkfs.ext4`
- busybox ash **不认 `$'...'`**
- **6M / 12M 固件不能互刷**，`sysupgrade` 不检查分区边界
- **别装 `owut` / `luci-app-attendedsysupgrade`**：ASU 用官方 ImageBuilder 重建，定制全丢，且缺 NSS 内核模块
- `luci-i18n-*` 是 HIDDEN 符号，直接写 `.config` 会被 `defconfig` 静默丢弃（依赖的 app 在才会被选中）
- 跑代理前别开软件卸载（`flow_offloading`），否则部分流量绕过 TUN/TPROXY
- 双频合一要真正引导频段得靠 `luci-app-usteer`（已编入）
- **这棵树的 `scripts/feeds` 不支持 `src-git url;<sha>` 直拼**——会把 SHA 当分支名 clone 失败；先 update 再 `git -C feeds/<name> checkout <sha>`（local-build.sh 已按此写）
- WSL2 编译两个坑：① 默认 root 下 GNU tar 拒绝 configure，需 `FORCE_UNSAFE_CONFIGURE=1`（脚本已内置）；② WSL 会把 Windows PATH 追加进来，rust 安装的 `find -execdir` 检测到带空格的非纯路径直接拒绝——脚本已把 PATH 洗成纯 Linux
- PassWall 的 xray/sing-box 核心运行时由它在 LuCI 里自己下载（走 GitHub，网络不稳时多试）
- **sqm-scripts-nss 装不上（生态缺口，2026-11-08 真机确认）**：它依赖的 `kmod-qca-nss-drv-qdisc` 在 laipeng668 的 feed 里不存在（qdisc kmod 是 qca-nss-clients 的补丁产物，当前 NSS-LibWrt 分支没打），构建时被 defconfig 降级成 `=m`（编出但不装），普通版 `sqm-scripts` 顶替进固件。构建脚本有红构建断言（`ALLOW_SQM_MISSING=1` 可显式放行）。**修复落地前别在 LuCI 开 SQM**——软件限速会把流量拉出 NSS 快路径还额外吃 CPU
- **default-settings-chn 会覆盖首启配置**：它按字典序排在 `99-ax1800` 之后执行，会重写 `dhcp.lan`（IPv6 RA/DHCPv6）和 `luci.main.lang`。已有 `zz-ax1800`（字典序最后）在其后重放设计值（IPv6 + 中文语言 + usteer 菜单汉化）
- **本仓库本地构建链的 WSL 专属坑（local-build.sh 已内置处理）**：root 下 GNU tar 拒绝 configure（`FORCE_UNSAFE_CONFIGURE=1`）；WSL 会把 Windows PATH 追加进来导致 rust 安装的 `find -execdir` 拒绝执行（脚本把 PATH 洗成纯 Linux）；codelinaro 重写过历史，nss_packages git 型包的锁定哈希对不上（脚本剥掉 `PKG_MIRROR_HASH`）；`scripts/feeds` 不支持 `;sha` 直拼（update 后手动 checkout）；WSL 的 `/tmp` 是 tmpfs，虚拟机空闲关机即清空（持久产物放 `/root`）

## 借鉴来源

本仓库的不少做法抄自同设备的优秀项目，排名不分先后：

| 来源 | 抄了什么 |
|---|---|
| [natserver/istoreos](https://github.com/natserver/istoreos)（同设备 iStoreOS 25.12，每几天一版） | 编译后 unsquashfs 镜像内容自检、CRLF 守卫、po 目录守卫思路、`/big.html` 12M 刷机入口 |
| [natserver/NatserverWrt](https://github.com/natserver/NatserverWrt)（同作者 NSS snapshot + daed） | 上游版本去重（Release grep 短 SHA） |
| [EmptyGhost/LibWrt-JDC-RE-SS-01-CI](https://github.com/EmptyGhost/LibWrt-JDC-RE-SS-01-CI)（同底座 CI） | 单条目 Release 模式、HiGarfield/cachewrtbuild 缓存 |
| [cookorz1/ax1800pro-cookwrt](https://github.com/cookorz1/ax1800pro-cookwrt)（LibWrt 系定制） | feeds.lock 可复现构建思路 |
| [ZqinKing/wrt_release](https://github.com/ZqinKing/wrt_release)（★720 多设备构建器） | 1GB 内存画像三件套、SKB 回收器、NSS Mesh/组播卸载（亚瑟档案 `jdcloud_ipq60xx_libwrt`） |
